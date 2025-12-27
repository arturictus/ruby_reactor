# frozen_string_literal: true

require_relative "executor/input_validator"
require_relative "executor/graph_manager"
require_relative "executor/retry_manager"
require_relative "executor/compensation_manager"
require_relative "executor/result_handler"
require_relative "executor/step_executor"

module RubyReactor
  class Executor
    attr_reader :reactor_class, :context, :dependency_graph, :compensation_manager, :retry_manager, :result_handler,
                :step_executor, :result

    def initialize(reactor_class, inputs = {}, context = nil)
      @reactor_class = reactor_class
      @context = context || Context.new(inputs, reactor_class)
      @dependency_graph = DependencyGraph.new
      @compensation_manager = CompensationManager.new(@context)
      @retry_manager = RetryManager.new(@context)
      @result_handler = ResultHandler.new(
        context: @context,
        compensation_manager: @compensation_manager,
        dependency_graph: @dependency_graph
      )
      @step_executor = StepExecutor.new(
        context: @context,
        dependency_graph: @dependency_graph,
        reactor_class: @reactor_class,
        managers: {
          retry_manager: @retry_manager,
          result_handler: @result_handler,
          compensation_manager: @compensation_manager
        }
      )
      @result = nil
    end

    def execute
      input_validator = InputValidator.new(@reactor_class, @context)
      input_validator.validate!

      save_context

      graph_manager = GraphManager.new(@reactor_class, @dependency_graph, @context)
      graph_manager.build_and_validate!
      graph_manager.mark_completed_steps_from_context

      @result = @step_executor.execute_all_steps
      update_context_status(@result)
      handle_interrupt(@result) if @result.is_a?(RubyReactor::InterruptResult)
      @result
    rescue StandardError => e
      @result = @result_handler.handle_execution_error(e)
      update_context_status(@result)
      @result
    ensure
      save_context
    end

    def resume_execution
      prepare_for_resume
      save_context

      @result = if @context.current_step
                  execute_current_step_and_continue
                else
                  execute_remaining_steps
                end

      update_context_status(@result)

      handle_interrupt(@result) if @result.is_a?(RubyReactor::InterruptResult)

      @result
    rescue StandardError => e
      handle_resume_error(e)
      update_context_status(@result)
      @result
    ensure
      save_context
    end

    def undo_all
      @compensation_manager.rollback_completed_steps
    end

    def undo_stack
      @compensation_manager.undo_stack
    end

    def undo_trace
      @compensation_manager.undo_trace
    end

    def execution_trace
      @context.execution_trace
    end

    def save_context
      storage = RubyReactor::Configuration.instance.storage_adapter
      reactor_class_name = @reactor_class.name || "AnonymousReactor-#{@reactor_class.object_id}"

      # Serialize context
      serialized_context = ContextSerializer.serialize(@context)
      storage.store_context(@context.context_id, serialized_context, reactor_class_name)
    end

    private

    def update_context_status(result)
      return unless result

      if result.is_a?(RubyReactor::AsyncResult)
        @context.status = :running
      elsif result.is_a?(RubyReactor::Success)
        @context.status = :completed
      elsif result.is_a?(RubyReactor::Failure)
        @context.status = :failed
        @context.failure_reason = {
          message: result.error.is_a?(Exception) ? result.error.message : result.error.to_s,
          step_name: result.step_name,
          inputs: result.inputs,
          backtrace: result.backtrace,
          reactor_name: result.reactor_name,
          step_arguments: result.step_arguments,
          exception_class: result.exception_class
        }
      elsif result.is_a?(RubyReactor::InterruptResult)
        @context.status = :paused
      end
    end

    def prepare_for_resume
      # Build dependency graph and mark completed steps
      graph_manager = GraphManager.new(@reactor_class, @dependency_graph, @context)
      graph_manager.build_and_validate!
      graph_manager.mark_completed_steps_from_context
    end

    def execute_current_step_and_continue
      step_config = @reactor_class.steps[@context.current_step]
      return RubyReactor::Failure("Step '#{@context.current_step}' not found in reactor") unless step_config

      # If current step is already in intermediate_results, skip directly to execute_all_steps
      return @step_executor.execute_all_steps if @context.intermediate_results.key?(@context.current_step.to_sym)

      # Use execute_step (not execute_step_with_retry) so that async steps can be handled properly in inline mode
      result = @step_executor.execute_step(step_config)

      # execute_step returns nil for inline async, meaning continue execution
      if result.nil?
        @result = @step_executor.execute_all_steps
      else
        case result
        when RetryQueuedResult, RubyReactor::Failure, RubyReactor::AsyncResult, RubyReactor::InterruptResult
          # Step was requeued, failed, or handed off to async - return the result
          @result = result
        when RubyReactor::Success
          # Step succeeded, continue with remaining steps
          @result = @step_executor.execute_all_steps
        end
      end
      @result
    end

    def execute_remaining_steps
      @result = @step_executor.execute_all_steps
      @result
    end

    def handle_resume_error(error)
      @result = @result_handler.handle_execution_error(error)
      @result
    end

    def handle_interrupt(interrupt_result)
      save_context

      # Store correlation ID mapping if present
      return unless interrupt_result.correlation_id

      storage = RubyReactor::Configuration.instance.storage_adapter
      storage.store_correlation_id(
        interrupt_result.correlation_id,
        @context.context_id,
        @reactor_class.name
      )
    end
  end
end
