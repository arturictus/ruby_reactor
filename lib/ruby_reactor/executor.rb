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

      graph_manager = GraphManager.new(@reactor_class, @dependency_graph, @context)
      graph_manager.build_and_validate!

      @result = @step_executor.execute_all_steps

      handle_interrupt(@result) if @result.is_a?(RubyReactor::InterruptResult)

      @result
    rescue StandardError => e
      @result = @result_handler.handle_execution_error(e)
    end

    def resume_execution
      prepare_for_resume

      @result = if @context.current_step
                  execute_current_step_and_continue
                else
                  execute_remaining_steps
                end

      handle_interrupt(@result) if @result.is_a?(RubyReactor::InterruptResult)

      @result
    rescue StandardError => e
      handle_resume_error(e)
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
      reactor_class_name = @reactor_class.name

      # Serialize context
      serialized_context = ContextSerializer.serialize(@context)
      storage.store_context(@context.context_id, serialized_context, reactor_class_name)
    end

    private

    def prepare_for_resume
      # Build dependency graph and mark completed steps
      graph_manager = GraphManager.new(@reactor_class, @dependency_graph, @context)
      graph_manager.build_and_validate!
      graph_manager.mark_completed_steps_from_context
    end

    def execute_current_step_and_continue
      step_config = @reactor_class.steps[@context.current_step]
      return RubyReactor::Failure("Step '#{@context.current_step}' not found in reactor") unless step_config

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
      # Only handle errors that haven't already triggered compensation
      # StepFailureError means compensation already happened, just convert to Failure
      @result = if error.is_a?(Error::StepFailureError)
                  RubyReactor.Failure(error.message)
                else
                  @result_handler.handle_execution_error(error)
                end
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
