# frozen_string_literal: true

module RubyReactor
  class Executor
    class RetryManager
      def initialize(context)
        @context = context
      end

      def execute_with_retry(step_config, reactor_class)
        loop do
          @context.retry_context.current_step = step_config.name
          @context.retry_context.increment_attempt_for_step(step_config.name)

          result = yield

          if result.is_a?(RubyReactor::Success)
            # Step succeeded, clear retry state
            clear_retry_state
            return result
          elsif result.is_a?(RubyReactor::Failure)
            # Step failed, check if we can retry
            if can_retry_step?(step_config) && result.retryable?
              if reactor_class.async?
                requeue_job_for_step_retry(step_config, result.error, reactor_class)
                return RetryQueuedResult.new(
                  step_config.name,
                  @context.retry_context.attempts_for_step(step_config.name),
                  @context.retry_context.next_retry_at
                )
              else
                # Sync retry - apply backoff delay and continue loop
                delay = calculate_backoff_delay(step_config, result.error, reactor_class)
                sleep(delay)
                # Continue loop to retry
              end
            else
              # Cannot retry, fail
              clear_retry_state
              current_attempts = @context.retry_context.attempts_for_step(step_config.name)
              error_message = result.error.respond_to?(:message) ? result.error.message : result.error.to_s
              return MaxRetriesExhaustedFailure.new(
                "Step '#{step_config.name}' failed after #{current_attempts} attempts: #{error_message}",
                step: step_config.name,
                attempts: current_attempts,
                original_error: result.error
              )
            end
          else
            # Unexpected result type
            clear_retry_state
            return RubyReactor::Failure("Step '#{step_config.name}' returned unexpected result: #{result.inspect}")
          end
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
        delay = calculate_backoff_delay(step_config, error, reactor_class)

        # Serialize context and requeue the job
        serialized_context = ContextSerializer.serialize(@context)
        configuration.worker_class.perform_in(delay, serialized_context, reactor_class.name)
      end

      def clear_retry_state
        @context.retry_context.current_step = nil
        @context.retry_context.failure_reason = nil
        @context.retry_context.next_retry_at = nil
      end

      def configuration
        RubyReactor::Configuration.instance
      end
    end
  end
end
