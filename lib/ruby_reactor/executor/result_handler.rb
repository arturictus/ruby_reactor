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
        when RubyReactor::Halt
          # Important: must come before Skipped and Success — both are Halt's
          # siblings under Success, and Halt takes precedence over either.
          handle_halt(step_config, result)
        when RubyReactor::Skipped
          # Must come before the Success branch — Skipped < Success.
          handle_skipped(step_config, result, resolved_arguments)
        when RubyReactor::Success
          handle_success(step_config, result, resolved_arguments)
        when RubyReactor::MaxRetriesExhaustedFailure
          handle_retries_exhausted(step_config, result, resolved_arguments)
        when RubyReactor::Failure
          handle_failure(step_config, result, resolved_arguments)
        when RubyReactor::InterruptResult
          handle_interrupted(step_config, resolved_arguments)
        else
          handle_unknown_result(step_config, result, resolved_arguments)
        end
      end

      # Every reactor-level Failure that follows a rollback is built here, so
      # this is the one place `rollback_failures` is attached (005 R-08).
      def handle_execution_error(error)
        with_rollback_failures(build_execution_failure(error))
      end

      # The end of a rollback that handed off (009 R-04): the Failure recorded
      # at the hand-off, with every rollback failure collected since.
      def handed_off_failure(failure)
        with_rollback_failures(failure)
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

      def with_rollback_failures(failure)
        failure.rollback_failures.concat(@compensation_manager.rollback_failures) if failure.is_a?(RubyReactor::Failure)
        failure
      end

      # Every error rolls back the completed steps first (Constitution II), then
      # becomes the run's Failure.
      def build_execution_failure(error)
        if error.is_a?(Error::StepFailureError)
          current_context = error.context || @context
          current_context.current_step = error.step
          store_failed_map_context(current_context) if current_context.map_metadata
        end
        handing_off_as(error) { @compensation_manager.rollback_completed_steps }
        failure_for(error)
      end

      # A rollback that hands off mid-way (009 R-04) carries the Failure this
      # run will end with, minus its rollback failures, to the executor that
      # records the hand-off. `error` is what the run fails with once the
      # rollback is done (a lambda when it is costly or not built yet).
      def handing_off_as(error)
        yield
      rescue Error::RollbackHandedOff => e
        e.failure ||= failure_for(error.respond_to?(:call) ? error.call : error)
        raise
      end

      def failure_for(error)
        case error
        when Error::StepFailureError
          create_failure_from_error(error, redacted_input_names(error.context))
        when Error::InputValidationError
          # Unified validation failure shape (inputs, step args, step output).
          build_validation_failure(error)
        when Error::Base
          # A `CompensationError` names the step whose compensation failed.
          RubyReactor.Failure("Execution error: #{error.message}", exception_class: error.class.name,
                                                                   step_name: error.step || @context.current_step,
                                                                   reactor_name: @context.reactor_class&.name)
        else
          # Any other StandardError after completed work (a checkpoint write,
          # a hook) still leaves a partial saga, rolled back like any failure
          # (Constitution II, 008 R-07); name the step that was executing.
          RubyReactor.Failure("Execution failed: #{error.message}", exception_class: error.class.name,
                                                                    step_name: @context.current_step,
                                                                    reactor_name: @context.reactor_class&.name)
        end
      end

      def redacted_input_names(context)
        return [] unless context&.reactor_class

        context.reactor_class.inputs.select { |_, config| config[:redact] }.keys
      end

      # Failure for a validation error (reactor inputs, step arguments, or
      # step output), carrying both the structured field errors and the step/
      # reactor attribution stamped at the raise site (nil step_name for
      # reactor-level input failures).
      def build_validation_failure(error)
        redact_inputs = []
        redact_inputs = @context.reactor_class.inputs.select { |_, c| c[:redact] }.keys if @context.reactor_class

        RubyReactor.Failure(
          error,
          validation_errors: error.field_errors,
          step_name: error.step_name,
          step_arguments: error.step_arguments || {},
          inputs: @context.inputs,
          redact_inputs: redact_inputs,
          reactor_name: @context.reactor_class&.name
        )
      end

      # A step returned `RubyReactor.Halt(...)`. Halt cleanly: record the
      # event in the trace, do NOT push to the undo stack (so existing
      # completed steps stay as-is — no compensation), and stamp the step
      # name on the result so the caller can see who halted.
      def handle_halt(step_config, result)
        @step_results[step_config.name] = result
        result.instance_variable_set(:@step_name, step_config.name) if result.step_name.nil?
        @context.append_execution_trace(
          {
            type: :halt,
            step: step_config.name,
            timestamp: Time.now,
            reason: result.reason
          }
        )
        result
      end

      # A composed child paused at an interrupt (010): the step stays
      # incomplete, and this run pauses on it. `with_step` cleared
      # `current_step` on the way out; it is the run's resume cursor. The
      # child's completed steps are only undone through this step, so it joins
      # the undo stack as a partial run, as an interrupted compose does (R-04).
      def handle_interrupted(step_config, resolved_arguments)
        @context.current_step = step_config.name
        return unless step_config.undoes_partial_run?

        @compensation_manager.add_to_undo_stack({ step: step_config,
                                                  arguments: step_config.rollback_arguments(resolved_arguments),
                                                  result: RubyReactor.Success(nil) })
      end

      # A step returned `RubyReactor.Skipped(...)`: the run continues exactly as
      # for a Success (value, hand-off, period mark), but the step is NOT pushed
      # for undo — it had nothing to do, so there is nothing to revert (008 R-19).
      def handle_skipped(step_config, result, resolved_arguments)
        validate_step_output(step_config, result.value, resolved_arguments)
        @step_results[step_config.name] = result
        @context.set_result(step_config.name, result.value)
        @dependency_graph.complete_step(step_config.name)
        @context.append_execution_trace(
          {
            type: :skipped,
            step: step_config.name,
            timestamp: Time.now,
            reason: result.reason
          }
        )
        result
      end

      def handle_success(step_config, result, resolved_arguments)
        validate_step_output(step_config, result.value, resolved_arguments)
        @step_results[step_config.name] = result
        if step_config.rollback_tracked?
          @compensation_manager.add_to_undo_stack({ step: step_config,
                                                    arguments: step_config.rollback_arguments(resolved_arguments),
                                                    result: result })
        end
        @context.set_result(step_config.name, result.value)
        @dependency_graph.complete_step(step_config.name)
      end

      # A composed child's Failure carries the child's own rollback failures;
      # fold them in BEFORE this level rolls back, so they come first.
      def adopt_rollback_failures(result)
        return unless result.respond_to?(:rollback_failures)

        @compensation_manager.rollback_failures.concat(result.rollback_failures)
      end

      def handle_retries_exhausted(step_config, result, resolved_arguments)
        adopt_rollback_failures(result)
        error = step_failure_error(step_config, result.error, result, resolved_arguments, cause: result.original_error)
        handing_off_as(error) do
          @compensation_manager.handle_step_failure(step_config, result.original_error, resolved_arguments)
        end
        raise error
      end

      def handle_failure(step_config, result, resolved_arguments)
        adopt_rollback_failures(result)
        message = @compensation_manager.step_failure_message(step_config, result.error)
        failure_result = handing_off_as(-> { step_failure_error(step_config, message, result, resolved_arguments) }) do
          @compensation_manager.handle_step_failure(step_config, result.error, resolved_arguments)
        end
        raise step_failure_error(step_config, failure_result.error, result, resolved_arguments)
      end

      # A step that propagates another unit's failure (an async_step reader, a
      # map adopting a fan-out element's Failure) keeps its field errors and
      # exception class on the reactor's failure.
      def step_failure_error(step_config, message, result, resolved_arguments, cause: result.error)
        orig_err = cause.is_a?(Exception) ? cause : nil
        error = Error::StepFailureError.new(message, step: step_config.name, context: @context,
                                                     original_error: orig_err,
                                                     step_arguments: resolved_arguments,
                                                     exception_class: (result.exception_class unless orig_err),
                                                     validation_errors: result.validation_errors)
        if result.respond_to?(:backtrace) && result.backtrace
          error.set_backtrace(result.backtrace)
        elsif orig_err
          error.set_backtrace(orig_err.backtrace)
        end
        error
      end

      # Wrapped first, so a returned `Step::Inputs` is validated and stored as its Hash.
      def handle_unknown_result(step_config, result, resolved_arguments)
        success_result = RubyReactor.Success(result)
        validate_step_output(step_config, success_result.value, resolved_arguments)
        @step_results[step_config.name] = success_result
        @compensation_manager.add_to_undo_stack({ step: step_config,
                                                  arguments: step_config.rollback_arguments(resolved_arguments),
                                                  result: success_result })
        @context.set_result(step_config.name, success_result.value)
        @dependency_graph.complete_step(step_config.name)
      end

      def store_failed_map_context(context)
        return unless context.map_metadata && context.map_metadata[:map_id]
        return unless Map::Helpers.normalize_arguments(context.map_metadata)[:atomic]

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
          code_snippet: code_snippet,
          validation_errors: error.validation_errors,
          retryable: error.retryable?
        )
      end

      def resolve_exception_class(original_error, error)
        # A step's own contention is reported by its cause (Lock::AcquisitionError, ...).
        original_error = original_error.original if original_error.is_a?(StepCoordination::Contended)
        # Argument failures report their cause's class (008 R-06).
        return original_error.exception_class if original_error.is_a?(Error::ArgumentResolutionError)
        return original_error.class.name if original_error

        error.respond_to?(:exception_class) ? error.exception_class : nil
      end

      def validate_step_output(step_config, value, resolved_arguments = {})
        return unless step_config.output_validator

        output_validation_result = step_config.output_validator.call(value)
        return if output_validation_result.success?

        error = output_validation_result.error
        error.step_name = step_config.name
        error.step_arguments = resolved_arguments

        # The step DID run — its side effect exists even though its output is
        # invalid. Treat it like a step failure: run the step's own
        # compensation and roll back prior steps, so the side effect is not
        # orphaned. Then surface the structured validation error (the later
        # rollback in handle_execution_error is a no-op — stack already clear).
        handing_off_as(error) { @compensation_manager.handle_step_failure(step_config, error, resolved_arguments) }
        raise error
      end

      def extract_location(backtrace)
        RubyReactor::Utils::BacktraceLocation.extract(backtrace)
      end
    end
  end
end
