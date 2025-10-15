# frozen_string_literal: true

module RubyReactor
  # Result returned when a step retry has been queued for async execution
  class RetryQueuedResult
    attr_reader :step_name, :attempt_number, :next_retry_at

    def initialize(step_name, attempt_number, next_retry_at)
      @step_name = step_name
      @attempt_number = attempt_number
      @next_retry_at = next_retry_at
    end

    def retry_queued?
      true
    end

    def success?
      false
    end

    def failure?
      false
    end
  end
end