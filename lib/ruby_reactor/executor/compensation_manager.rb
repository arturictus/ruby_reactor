# frozen_string_literal: true

module RubyReactor
  class Executor
    class CompensationManager
      # Raised ONLY before the step's body: by its own coordination, or while
      # resolving its arguments (008 R-06).
      # A coordination error raised from inside a body (a nested direct
      # `Step.run`) arrives as `StepCoordination::NestedCoordinationError`, and
      # a bare `Lock::AcquisitionError` etc. may come from a nested
      # `Reactor.run` — both mean the body ran, so neither is listed here.
      NEVER_STARTED_ERROR_CLASSES = [
        RubyReactor::Executor::StepCoordination::Contended,
        RubyReactor::Executor::StepCoordination::KeyError,
        RubyReactor::Executor::StepCoordination::DispatchRefused,
        RubyReactor::Error::ArgumentResolutionError
      ].freeze

      def initialize(context)
        @context = context
        @undo_trace = []
        @rollback_failures = []
      end

      def undo_stack
        @context.undo_stack
      end

      # Every undo/compensation that did not complete, in rollback order
      # (005 FR-004). `ResultHandler` attaches it to the final Failure.
      attr_reader :undo_trace, :rollback_failures

      def add_to_undo_stack(step_info)
        @context.undo_stack << step_info
      end

      def handle_step_failure(step_config, error, arguments)
        # A step whose OWN coordination acquisition failed (contention, or a
        # bad key proc) never ran its body — "no step compensates, the
        # contended step's work has not been attempted" (US3-1/T018), which
        # applies here exactly as it does to a worker park: compensating a
        # step that never started is meaningless, and attempting one would
        # try to re-acquire the very key that is (usually) still contended,
        # turning a plain contention failure into a confusing
        # CompensationError. Prior steps still roll back normally.
        if step_never_started?(error)
          rollback_completed_steps
          return RubyReactor.Failure("Step '#{step_config.name}' failed: #{error}")
        end

        # Try compensation
        compensation_result = compensate_step(step_config, error, arguments)
        case compensation_result
        when RubyReactor::Success
          # Compensation succeeded, continue with rollback
          rollback_completed_steps
          RubyReactor.Failure("Step '#{step_config.name}' failed: #{error}")
        when RubyReactor::Failure
          # Compensation failed, this is more serious
          rollback_completed_steps
          raise Error::CompensationError.new(
            "Compensation for step '#{step_config.name}' failed: #{compensation_result.error}",
            step: step_config.name,
            context: @context,
            original_error: error
          )
        end
      end

      # A unit that compensates itself outside the executor loop (StepWorker's
      # `async_step`): the same coordination re-take, trace, middleware events
      # and `rollback_failures` as a step compensated here.
      def compensate(step_config, error, arguments)
        compensate_step(step_config, error, arguments)
      end

      # Newest first. Each entry leaves the stack only once its undo returned,
      # so an interruption mid-rollback leaves exactly the entries still to
      # undo — the interrupted one included — for a manual undo (008 R-16).
      def rollback_completed_steps
        until undo_stack.empty?
          step_info = undo_stack.last
          result = @context.with_step(step_info[:step].name) do
            undo_step(step_info[:step], step_info[:result], step_info[:arguments])
          end
          undo_stack.pop
          @undo_trace << { type: :undo, step: step_info[:step].name, result: result,
                           arguments: step_info[:arguments] }
        end
      end

      private

      def middlewares
        @context.middlewares || RubyReactor::MiddlewareRunner.new([])
      end

      # Ensure we have a value to log (if it's a Success/Failure object, get the value or error)
      def loggable_value(result)
        if result.respond_to?(:value)
          result.value
        elsif result.respond_to?(:error)
          result.error
        else
          result
        end
      end

      def skipped_result?(result)
        result.respond_to?(:skipped?) && result.skipped?
      end

      def step_never_started?(error)
        NEVER_STARTED_ERROR_CLASSES.any? { |klass| error.is_a?(klass) }
      end

      # US6/T047: re-take a step's own lock/semaphore around its compensate
      # or undo body, so a concurrent forward execution cannot enter the
      # step's critical section while rollback is undoing what it protected.
      # A no-op when the step declares no coordination.
      def coordinated_rollback(step_config, arguments, &block)
        return block.call if Executor::StepCoordination.none?(step_config)

        # The undo stack stores the RESOLVED arguments; the forward key was
        # computed from `coordination_arguments` of them, so rollback does the
        # same and re-takes the very key the forward run held.
        Executor::StepCoordination.new(
          step_config: step_config, arguments: step_config.coordination_arguments(arguments, @context.inputs),
          context: @context, reactor_class: @context.reactor_class, middlewares: middlewares
        ).around_rollback(&block)
      end

      # Under `with_step`, as `rollback_completed_steps` runs each undo: a
      # construct (compose, map) reads `context.current_step` to find its own
      # state during either rollback moment.
      def compensate_step(step_config, error, arguments)
        @context.with_step(step_config.name) { compensate_step_body(step_config, error, arguments) }
      end

      def compensate_step_body(step_config, error, arguments)
        middlewares.on(:start_compensation, step_config.name, error, arguments, @context)
        begin
          compensate_result = coordinated_rollback(step_config, arguments) do
            step_config.call_compensate(error, arguments, @context)
          end

          @context.append_execution_trace(
            {
              type: :compensate,
              step: step_config.name,
              timestamp: Time.now,
              result: loggable_value(compensate_result),
              arguments: arguments,
              skipped: skipped_result?(compensate_result)
            }
          )
          @undo_trace << { type: :compensation, step: step_config.name, error: error, arguments: arguments }

          if compensate_result.is_a?(RubyReactor::Failure)
            record_rollback_failure(step_config.name, :compensate, compensate_result)
            middlewares.on(:failed_compensation, step_config.name, compensate_result, @context)
          else
            middlewares.on(:complete_compensation, step_config.name, compensate_result, @context)
          end

          compensate_result
        rescue Error::Rescuable => e
          record_rollback_failure(step_config.name, :compensate, e)
          middlewares.on(:failed_compensation, step_config.name, e, @context)
          # A raise is a compensation failure like a returned Failure: the
          # caller still rolls back the completed steps, then raises
          # `CompensationError`. Re-raising here skipped both.
          RubyReactor.Failure(e)
        end
      end

      def undo_step(step_config, result, arguments)
        middlewares.on(:start_undo, step_config.name, result, arguments, @context)
        begin
          undo_result = coordinated_rollback(step_config, arguments) do
            step_config.call_undo(result.value, arguments, @context)
          end

          @context.append_execution_trace(
            {
              type: :undo,
              step: step_config.name,
              timestamp: Time.now,
              result: loggable_value(undo_result),
              arguments: arguments,
              skipped: skipped_result?(undo_result)
            }
          )

          if undo_result.is_a?(RubyReactor::Failure)
            record_rollback_failure(step_config.name, :undo, undo_result)
            middlewares.on(:failed_undo, step_config.name, undo_result, @context)
          else
            middlewares.on(:complete_undo, step_config.name, undo_result, @context)
          end

          undo_result
        rescue Error::Rescuable => e
          record_rollback_failure(step_config.name, :undo, e)
          middlewares.on(:failed_undo, step_config.name, e, @context)
          # Log undo failure but don't halt the rollback process
          @context.append_execution_trace(
            { type: :undo_failure, step: step_config.name, timestamp: Time.now, error: e.message }
          )
          RubyReactor.Failure(e)
        end
      end

      # `outcome` is the Failure an undo/compensate returned, or the exception
      # it raised. A composed child's Failure already carries its own list —
      # flatten it instead of adding one opaque entry for the compose step.
      def record_rollback_failure(step_name, kind, outcome)
        if outcome.is_a?(RubyReactor::Failure) && outcome.rollback_failures.any?
          @rollback_failures.concat(outcome.rollback_failures)
          return
        end

        error = outcome.is_a?(RubyReactor::Failure) ? outcome.error : outcome
        contended = error.is_a?(StepCoordination::Contended)
        reason = if contended
                   :coordination_unavailable
                 elsif outcome.is_a?(Exception)
                   :raised
                 else
                   :returned_failure
                 end
        @rollback_failures << {
          step: step_name.to_sym, kind: kind, key: (error.key if contended), reason: reason,
          message: error.respond_to?(:message) ? error.message : error.to_s
        }
      end
    end
  end
end
