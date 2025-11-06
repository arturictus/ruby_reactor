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
      @result_handler = ResultHandler.new(@context, @compensation_manager, @dependency_graph)
      @step_executor = StepExecutor.new(@context, @dependency_graph, @retry_manager, @result_handler, @reactor_class,
                                        @compensation_manager)
      @result = nil
    end

    def execute
      input_validator = InputValidator.new(@reactor_class, @context)
      input_validator.validate!

      graph_manager = GraphManager.new(@reactor_class, @dependency_graph, @context)
      graph_manager.build_and_validate!

      @result = @step_executor.execute_all_steps
    rescue StandardError => e
      @result = @result_handler.handle_execution_error(e)
    end

    def resume_execution
      # Resume execution from the current state
      # This is called when a job is requeued after a step retry

      # Build dependency graph and mark completed steps
      graph_manager = GraphManager.new(@reactor_class, @dependency_graph, @context)
      graph_manager.build_and_validate!
      graph_manager.mark_completed_steps_from_context

      # If there's a current_step, it means we need to execute that step
      if @context.current_step
        step_config = @reactor_class.steps[@context.current_step]
        return RubyReactor::Failure("Step '#{@context.current_step}' not found in reactor") unless step_config

        # Use execute_step (not execute_step_with_retry) so that async steps can be handled properly in inline mode
        result = @step_executor.execute_step(step_config)

        # execute_step returns nil for inline async, meaning continue execution
        if result.nil?
          @result = @step_executor.execute_all_steps
          @result
        else
          case result
          when RetryQueuedResult, RubyReactor::Failure, RubyReactor::AsyncResult
            # Step was requeued, failed, or handed off to async - return the result
            @result = result
            result
          when RubyReactor::Success
            # Step succeeded, continue with remaining steps
            @result = @step_executor.execute_all_steps
            @result
          end
        end
      else
        # No current step, execute remaining steps
        @result = @step_executor.execute_all_steps
        @result
      end
    rescue StandardError => e
      # Only handle errors that haven't already triggered compensation
      # StepFailureError means compensation already happened, just convert to Failure
      if e.is_a?(Error::StepFailureError)
        @result = RubyReactor.Failure(e.message)
        @result
      else
        @result = @result_handler.handle_execution_error(e)
        @result
      end
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
  end
end
