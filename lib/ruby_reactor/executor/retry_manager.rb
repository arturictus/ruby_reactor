# frozen_string_literal: true

module RubyReactor
  class Executor
    class RetryManager
      def initialize(context, middlewares = nil)
        @context = context
        @middlewares = middlewares || context.middlewares || Executor.middlewares_for(context.reactor_class)
      end

      def execute_with_retry(step_config, reactor_class)
        loop do
          prepare_retry_attempt(step_config)
          result = yield
          # A RetryQueuedResult from a contention park passes straight
          # through here unchanged (T023) — `handle_retry_result`'s
          # `RetryQueuedResult, DispatchResult` branch returns it verbatim,
          # so `execute_with_retry`'s loop exits on the same result a
          # genuine async-retry requeue would produce.
          handled_result = handle_retry_result(step_config, reactor_class, result)
          return handled_result if handled_result
        end
      end

      # Park the execution on step-level contention (US3): requeue at that
      # step, bounded by `lock_snooze_max_attempts`, with its own counter
      # (`RetryContext#contention_attempts`) so a busy key can never exhaust
      # the retry budget meant for genuine failures (Finding 2).
      def park_for_contention(step_config, contended, reactor_class)
        # Give back the failure-retry attempt `prepare_retry_attempt` just
        # incremented for this round — a contention park is not a retry
        # attempt (Finding 2).
        @context.retry_context.decrement_attempt_for_step(step_config.name)

        config = RubyReactor.configuration
        count = @context.retry_context.increment_contention_for_step(step_config.name)

        # OrderedLock::WaitError is exempt from the cap — same exemption
        # `Worker#handle_snooze` makes for it: its own poison-pill timeout is
        # the only meaningful upper bound.
        uncapped = contended.original.is_a?(RubyReactor::OrderedLock::WaitError)
        if !uncapped && config.lock_snooze_max_attempts != :infinity && count > config.lock_snooze_max_attempts
          # Carry the contention through as a `Contended`, not a bare string:
          # `handle_non_retryable_failure` hands `result.error` to the
          # compensation manager as `original_error`, and `step_never_started?`
          # must still recognise that this step's body never ran — otherwise it
          # compensates work that never happened.
          return RubyReactor::Failure(
            Executor::StepCoordination::Contended.new(
              primitive: contended.primitive, key: contended.key, step_name: step_config.name,
              reactor_name: reactor_class.name, original: contended.original,
              message: "Step '#{step_config.name}' gave up on #{contended.primitive} '#{contended.key}' after " \
                       "#{count} contention attempts"
            ),
            step_name: step_config.name, reactor_name: reactor_class.name, retryable: false,
            exception_class: contended.original.class.name
          )
        end

        delay = RubyReactor::Worker.snooze_delay(config, contended)
        @context.retry_context.next_retry_at = Time.now + delay
        requeue_result = requeue_job(step_config, delay)

        if requeue_result.is_a?(RubyReactor::DispatchResult)
          RetryQueuedResult.new(step_config.name, @context.retry_context.attempts_for_step(step_config.name),
                                @context.retry_context.next_retry_at)
        else
          requeue_result
        end
      end

      private

      def can_retry_step?(step_config)
        step_config.retryable? && @context.retry_context.can_retry_step?(step_config.name,
                                                                         step_config.retry_config[:max_attempts])
      end

      def calculate_backoff_delay(step_config, _error, reactor_class)
        attempt_number = @context.retry_context.attempts_for_step(step_config.name)
        backoff_strategy = step_config.retry_config[:backoff] || reactor_class.retry_defaults[:backoff]
        base_delay = step_config.retry_config[:base_delay] || reactor_class.retry_defaults[:base_delay]

        delay = RetryContext.calculate_backoff_delay(attempt_number, backoff_strategy, base_delay)
        @context.retry_context.next_retry_at = Time.now + delay
        delay
      end

      def requeue_job_for_step_retry(step_config, error, reactor_class)
        @context.current_step = step_config.name
        delay = calculate_backoff_delay(step_config, error, reactor_class)

        requeue_job(step_config, delay)
      end

      # The requeue itself, given an already-decided delay. Split out of
      # `requeue_job_for_step_retry` (T021) so a contention park
      # (`RetryManager#park_for_contention`, US3) can reuse the identical
      # requeue mechanics with its own (snooze, not backoff) delay.
      def requeue_job(_step_config, delay)
        # Serialize context and requeue the job
        # Use root context if available to ensure we serialize the full tree
        # BUT for map elements (which have map_metadata), we must serialize the element context itself

        context_to_serialize = if @context.map_metadata
                                 @context
                               else
                                 @context.root_context || @context
                               end

        reactor_class_name = RubyReactor.reactor_storage_name(context_to_serialize.reactor_class)

        @middlewares.on(:before_async_enqueue, context_to_serialize)

        serialized_context = ContextSerializer.serialize(context_to_serialize)

        if @context.map_metadata
          map_args = @context.map_metadata.transform_keys(&:to_sym)
          configuration.async_router.perform_map_element_in(
            delay,
            map_id: map_args[:map_id],
            element_id: map_args[:element_id],
            index: map_args[:index],
            serialized_inputs: map_args[:serialized_inputs],
            reactor_class_info: map_args[:reactor_class_info],
            strict_ordering: map_args[:strict_ordering],
            parent_context_id: map_args[:parent_context_id],
            parent_reactor_class_name: map_args[:parent_reactor_class_name],
            step_name: map_args[:step_name],
            batch_size: map_args[:batch_size],
            serialized_context: serialized_context,
            fail_fast: map_args[:fail_fast]
          )
        else
          # Persist BEFORE enqueue — the job payload is identity-only (F2). The
          # rescheduled job rehydrates the root by id from storage.
          configuration.storage_adapter.store_context(
            context_to_serialize.context_id, serialized_context, reactor_class_name
          )
          configuration.async_router.perform_in(delay, context_to_serialize.context_id, reactor_class_name)
        end
      end

      def clear_retry_state
        @context.retry_context.current_step = nil
        @context.retry_context.failure_reason = nil
        @context.retry_context.next_retry_at = nil
      end

      def prepare_retry_attempt(step_config)
        @context.retry_context.current_step = step_config.name
        @context.retry_context.increment_attempt_for_step(step_config.name)
      end

      def handle_retry_result(step_config, reactor_class, result)
        case result
        when RubyReactor::Halt, RubyReactor::Skipped, RubyReactor::Success
          # Halt and Skipped are Success subclasses, so they already take this
          # path via inheritance; the explicit arms are readability plus a
          # guard against a future hierarchy change (R5).
          clear_retry_state
          result
        when RubyReactor::Failure
          handle_failure_result(step_config, reactor_class, result)
        when RetryQueuedResult, RubyReactor::DispatchResult
          # Pass through async results
          result
        else
          clear_retry_state
          RubyReactor::Failure("Step '#{step_config.name}' returned unexpected result: #{result.inspect}")
        end
      end

      def handle_failure_result(step_config, reactor_class, result)
        if can_retry_step?(step_config) && result.retryable?
          handle_retryable_failure(step_config, reactor_class, result)
        else
          handle_non_retryable_failure(step_config, result, reactor_class)
        end
      end

      def handle_retryable_failure(step_config, reactor_class, result)
        attempt_number = @context.retry_context.attempts_for_step(step_config.name)
        @middlewares.on(
          :retry_attempt,
          step_config.name,
          attempt_number,
          result.error,
          @context
        )

        # Check if we should requeue (async retry). The per-step `async` flag is
        # gone: a step relocated by `background` fails inside the worker, where
        # `inline_async_execution` already answers this — and a step failing
        # BEFORE the hand-off point genuinely has no worker to requeue into, so
        # it must retry synchronously.
        is_async = reactor_class.async? ||
                   @context.root_context&.reactor_class&.async? ||
                   @context.inline_async_execution

        # Always try async retry if configured
        if is_async
          handle_async_retry(step_config, reactor_class, result)
        else
          handle_sync_retry(step_config, reactor_class, result)
        end
      end

      def handle_async_retry(step_config, reactor_class, result)
        requeue_result = requeue_job_for_step_retry(step_config, result.error, reactor_class)

        # If it returned an DispatchResult, we are truly async.
        # Otherwise, it ran inline and we should return the result of that execution.
        if requeue_result.is_a?(RubyReactor::DispatchResult)
          RetryQueuedResult.new(
            step_config.name,
            @context.retry_context.attempts_for_step(step_config.name),
            @context.retry_context.next_retry_at
          )
        else
          requeue_result
        end
      end

      def handle_sync_retry(step_config, reactor_class, result)
        delay = calculate_backoff_delay(step_config, result.error, reactor_class)
        sleep(delay)
        nil # continue loop
      end

      def handle_non_retryable_failure(step_config, result, reactor_class)
        clear_retry_state
        current_attempts = @context.retry_context.attempts_for_step(step_config.name)
        error_message = result.error.respond_to?(:message) ? result.error.message : result.error.to_s
        MaxRetriesExhaustedFailure.new(
          "Step '#{step_config.name}' failed after #{current_attempts} attempts: #{error_message}",
          step: step_config.name,
          attempts: current_attempts,
          original_error: result.error,
          inputs: result.respond_to?(:inputs) ? result.inputs : {},
          backtrace: result.respond_to?(:backtrace) ? result.backtrace : nil,
          redact_inputs: if result.respond_to?(:instance_variable_get)
                           result.instance_variable_get(:@redact_inputs)
                         else
                           []
                         end,
          reactor_name: reactor_class.name,
          step_arguments: result.respond_to?(:step_arguments) ? result.step_arguments : {},
          validation_errors: result.validation_errors
        )
      end

      def configuration
        RubyReactor::Configuration.instance
      end
    end
  end
end
