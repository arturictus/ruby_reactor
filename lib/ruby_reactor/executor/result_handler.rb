# frozen_string_literal: true

module RubyReactor
  class Executor
    class ResultHandler
      def initialize(context:, compensation_manager:, dependency_graph:)
        @context = context
        @compensation_manager = compensation_manager
        @dependency_graph = dependency_graph
        @step_results = {}
      end

      attr_reader :step_results

      def handle_step_result(step_config, result, resolved_arguments)
        case result
        when RubyReactor::Success
          handle_success(step_config, result, resolved_arguments)
        when RubyReactor::MaxRetriesExhaustedFailure
          handle_retries_exhausted(step_config, result, resolved_arguments)
        when RubyReactor::Failure
          handle_failure(step_config, result, resolved_arguments)
        else
          handle_unknown_result(step_config, result, resolved_arguments)
        end
      end

      def handle_execution_error(error)
        case error
        when Error::StepFailureError
          handle_step_failure_error(error)
        when Error::InputValidationError
          # Preserve validation errors as-is for proper error handling
          RubyReactor.Failure(error, validation_errors: error.field_errors)
        when Error::Base
          # Other errors need rollback
          @compensation_manager.rollback_completed_steps
          RubyReactor.Failure("Execution error: #{error.message}", exception_class: error.class.name)
        else
          # Unknown errors - don't rollback as they may not be reactor-related
          RubyReactor.Failure("Execution failed: #{error.message}", exception_class: error.class.name)
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

      def handle_success(step_config, result, resolved_arguments)
        validate_step_output(step_config, result.value, resolved_arguments)
        @step_results[step_config.name] = result
        @compensation_manager.add_to_undo_stack({ step: step_config, arguments: resolved_arguments, result: result })
        @context.set_result(step_config.name, result.value)
        @dependency_graph.complete_step(step_config.name)
      end

      def handle_retries_exhausted(step_config, result, resolved_arguments)
        @compensation_manager.handle_step_failure(step_config, result.original_error, resolved_arguments)
        orig_err = result.original_error.is_a?(Exception) ? result.original_error : nil
        error = Error::StepFailureError.new(result.error, step: step_config.name, context: @context,
                                                          original_error: orig_err,
                                                          step_arguments: resolved_arguments)
        if result.respond_to?(:backtrace) && result.backtrace
          error.set_backtrace(result.backtrace)
        elsif orig_err
          error.set_backtrace(orig_err.backtrace)
        end
        raise error
      end

      def handle_failure(step_config, result, resolved_arguments)
        failure_result = @compensation_manager.handle_step_failure(step_config, result.error, resolved_arguments)
        orig_err = result.error.is_a?(Exception) ? result.error : nil
        error = Error::StepFailureError.new(failure_result.error, step: step_config.name, context: @context,
                                                                  original_error: orig_err,
                                                                  step_arguments: resolved_arguments)
        if result.respond_to?(:backtrace) && result.backtrace
          error.set_backtrace(result.backtrace)
        elsif orig_err
          error.set_backtrace(orig_err.backtrace)
        end
        raise error
      end

      def handle_unknown_result(step_config, result, resolved_arguments)
        validate_step_output(step_config, result, resolved_arguments)
        success_result = RubyReactor.Success(result)
        @step_results[step_config.name] = success_result
        @compensation_manager.add_to_undo_stack({ step: step_config, arguments: resolved_arguments,
                                                  result: success_result })
        @context.set_result(step_config.name, result)
        @dependency_graph.complete_step(step_config.name)
      end

      def handle_step_failure_error(error)
        current_context = error.context || @context
        current_context.current_step = error.step

        store_failed_map_context(current_context) if current_context.map_metadata

        @compensation_manager.rollback_completed_steps

        redact_inputs = []
        if error.context&.reactor_class
          redact_inputs = error.context.reactor_class.inputs.select { |_, config| config[:redact] }.keys
        end

        create_failure_from_error(error, redact_inputs)
      end

      def store_failed_map_context(context)
        return unless context.map_metadata && context.map_metadata[:map_id]
        return unless context.map_metadata[:fail_fast]

        storage = RubyReactor.configuration.storage_adapter
        storage.store_map_failed_context_id(
          context.map_metadata[:map_id],
          context.context_id,
          context.map_metadata[:parent_reactor_class_name]
        )
      end

      def create_failure_from_error(error, redact_inputs)
        original_error = error.original_error
        exception_class = resolve_exception_class(original_error, error)
        backtrace = original_error&.backtrace || error.backtrace
        file_path, line_number = extract_location(backtrace)
        code_snippet = RubyReactor::Utils::CodeExtractor.extract(file_path, line_number) if file_path

        RubyReactor.Failure(
          error.message,
          step_name: error.step,
          inputs: error.context.inputs,
          redact_inputs: redact_inputs,
          backtrace: backtrace,
          reactor_name: error.context.reactor_class.name,
          step_arguments: error.step_arguments,
          exception_class: exception_class,
          file_path: file_path,
          line_number: line_number,
          code_snippet: code_snippet
        )
      end

      def resolve_exception_class(original_error, error)
        return original_error.class.name if original_error

        error.respond_to?(:exception_class) ? error.exception_class : nil
      end

      def validate_step_output(step_config, value, resolved_arguments = {})
        return unless step_config.output_validator

        output_validation_result = step_config.output_validator.call(value)
        return if output_validation_result.success?

        raise Error::StepFailureError.new(
          "Step '#{step_config.name}' output validation failed: #{output_validation_result.error.message}",
          step: step_config.name,
          context: @context,
          step_arguments: resolved_arguments
        )
      end

      def extract_location(backtrace)
        return [nil, nil] unless backtrace && !backtrace.empty?

        # Filter out internal reactor frames if needed, or just take the first one
        # For now, let's take the first line of the backtrace which should be the error source
        # But we might want to skip our own internal frames if we want to point to user code
        # Let's start with the top frame, assuming backtrace is already correct (from original error)

        first_line = backtrace.first
        match = first_line.match(/^(.+?):(\d+)(?::in `.*')?$/)
        return [nil, nil] unless match

        [match[1], match[2].to_i]
      end
    end
  end
end
