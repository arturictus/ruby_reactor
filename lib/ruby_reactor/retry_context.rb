# frozen_string_literal: true

module RubyReactor
  # Tracks retry attempts and state for steps in async execution
  class RetryContext
    attr_accessor :step_attempts, :current_step, :failure_reason, :next_retry_at

    def initialize
      @step_attempts = {}
      @current_step = nil
      @failure_reason = nil
      @next_retry_at = nil
    end

    def increment_attempt_for_step(step_name)
      @step_attempts[step_name] ||= 0
      @step_attempts[step_name] += 1
    end

    def attempts_for_step(step_name)
      @step_attempts[step_name] || 0
    end

    def can_retry_step?(step_name, max_attempts)
      attempts_for_step(step_name) < max_attempts
    end

    def reset
      @step_attempts = {}
      @current_step = nil
      @failure_reason = nil
      @next_retry_at = nil
    end
  end
end