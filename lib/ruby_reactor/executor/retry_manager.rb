# frozen_string_literal: true

module RubyReactor
  class Executor
    class RetryManager
      def initialize(context)
        @context = context
      end

      def execute_with_retry(step_config, reactor_class)
        loop do
          prepare_retry_attempt(step_config)
          result = yield
          handled_result = handle_retry_result(step_config, reactor_class, result)
          return handled_result if handled_result
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

        # Serialize context and requeue the job
        # Use root context if available to ensure we serialize the full tree
        context_to_serialize = @context.root_context || @context
        reactor_class_name = context_to_serialize.reactor_class.name

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
            serialized_context: serialized_context
          )
        else
          configuration.async_router.perform_in(delay, serialized_context, reactor_class_name)
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
        when RubyReactor::Success
          clear_retry_state
          result
        when RubyReactor::Failure
          handle_failure_result(step_config, reactor_class, result)
        when RetryQueuedResult, RubyReactor::AsyncResult
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
        # Check if we should requeue (async retry)
        is_async = reactor_class.async? || step_config.async? ||
                   @context.root_context&.reactor_class&.async? ||
                   @context.inline_async_execution

        if is_async && !@context.test_mode
          handle_async_retry(step_config, reactor_class, result)
        else
          handle_sync_retry(step_config, reactor_class, result)
        end
      end

      def handle_async_retry(step_config, reactor_class, result)
        requeue_job_for_step_retry(step_config, result.error, reactor_class)
        RetryQueuedResult.new(
          step_config.name,
          @context.retry_context.attempts_for_step(step_config.name),
          @context.retry_context.next_retry_at
        )
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
          step_arguments: result.respond_to?(:step_arguments) ? result.step_arguments : {}
        )
      end

      def configuration
        RubyReactor::Configuration.instance
      end
    end
  end
end
