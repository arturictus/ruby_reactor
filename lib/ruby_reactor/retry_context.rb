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
      step_name = step_name.to_s
      @step_attempts[step_name] ||= 0
      @step_attempts[step_name] += 1
    end

    def attempts_for_step(step_name)
      step_name = step_name.to_s
      @step_attempts[step_name] || 0
    end

    def can_retry_step?(step_name, max_attempts)
      attempts = attempts_for_step(step_name)
      attempts < max_attempts
    end

    def reset
      @step_attempts = {}
      @current_step = nil
      @failure_reason = nil
      @next_retry_at = nil
    end

    def serialize_for_retry
      {
        step_attempts: @step_attempts,
        current_step: @current_step,
        failure_reason: serialize_error(@failure_reason),
        next_retry_at: @next_retry_at&.iso8601
      }
    end

    def self.deserialize_from_retry(data)
      context = new
      context.step_attempts = data["step_attempts"] || {}
      context.current_step = data["current_step"]
      context.failure_reason = deserialize_error(data["failure_reason"])
      context.next_retry_at = data["next_retry_at"] ? Time.iso8601(data["next_retry_at"]) : nil
      context
    end

    def self.calculate_backoff_delay(attempt_number, backoff_strategy, base_delay)
      case backoff_strategy
      when :exponential
        base_delay * (2**(attempt_number - 1))
      when :linear
        base_delay * attempt_number
      when :fixed
        base_delay
      else
        raise ArgumentError, "Unknown backoff strategy: #{backoff_strategy}"
      end
    end

    private

    def serialize_error(error)
      return nil unless error

      {
        class: error.class.name,
        message: error.message,
        backtrace: error.backtrace
      }
    end

    def self.deserialize_error(data)
      return nil unless data

      error_class = data["class"] ? Object.const_get(data["class"]) : StandardError
      error = error_class.new(data["message"])
      error.set_backtrace(data["backtrace"]) if data["backtrace"]
      error
    end

    private_class_method :deserialize_error
  end
end
