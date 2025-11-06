# frozen_string_literal: true

module RubyReactor
  class Executor
    class ResultHandler
      def initialize(context, compensation_manager, dependency_graph)
        @context = context
        @compensation_manager = compensation_manager
        @dependency_graph = dependency_graph
        @step_results = {}
      end

      attr_reader :step_results

      def handle_step_result(step_config, result, resolved_arguments)
        case result
        when RubyReactor::Success
          validate_step_output(step_config, result.value)
          @step_results[step_config.name] = result
          @compensation_manager.add_to_undo_stack({ step: step_config, arguments: resolved_arguments, result: result })
          @context.set_result(step_config.name, result.value)
          @dependency_graph.complete_step(step_config.name)
        when RubyReactor::MaxRetriesExhaustedFailure
          # For MaxRetriesExhaustedFailure, use the original error to avoid double-wrapping the message
          # The error message from MaxRetriesExhaustedFailure already includes "failed after N attempts"
          @compensation_manager.handle_step_failure(step_config, result.original_error, resolved_arguments)
          # Use the MaxRetriesExhaustedFailure error message for the final error
          raise Error::StepFailureError.new(result.error, step: step_config.name, context: @context)
        when RubyReactor::Failure
          failure_result = @compensation_manager.handle_step_failure(step_config, result.error, resolved_arguments)
          raise Error::StepFailureError.new(failure_result.error, step: step_config.name, context: @context)
        else
          # Treat non-Success/Failure results as success with that value
          validate_step_output(step_config, result)
          success_result = RubyReactor.Success(result)
          @step_results[step_config.name] = success_result
          @compensation_manager.add_to_undo_stack({ step: step_config, arguments: resolved_arguments,
                                                    result: success_result })
          @context.set_result(step_config.name, result)
          @dependency_graph.complete_step(step_config.name)
        end
      end

      def handle_execution_error(error)
        case error
        when Error::StepFailureError
          # Step failure has already been handled (compensation and rollback for the failed step)
          # But we need to rollback all completed steps
          @compensation_manager.rollback_completed_steps
          RubyReactor.Failure(error.message)
        when Error::InputValidationError
          # Preserve validation errors as-is for proper error handling
          RubyReactor.Failure(error)
        when Error::Base
          # Other errors need rollback
          @compensation_manager.rollback_completed_steps
          RubyReactor.Failure(error.message)
        else
          # Unknown errors need rollback
          @compensation_manager.rollback_completed_steps
          RubyReactor.Failure("Execution failed: #{error.message}")
        end
      end

      def final_result(reactor_class)
        if reactor_class.return_step
          result_value = @context.get_result(reactor_class.return_step)
          RubyReactor.Success(result_value)
        else
          RubyReactor.Success(@context.intermediate_results)
        end
      end

      private

      def validate_step_output(step_config, value)
        return unless step_config.output_validator

        output_validation_result = step_config.output_validator.call(value)
        return if output_validation_result.success?

        raise Error::StepFailureError.new(
          "Step '#{step_config.name}' output validation failed: #{output_validation_result.error.message}",
          step: step_config.name,
          context: @context
        )
      end
    end
  end
end
