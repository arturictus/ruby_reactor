# frozen_string_literal: true

module RubyReactor
  class MaxRetriesExhaustedFailure < Failure
    attr_reader :step_name, :attempts, :original_error

    def initialize(message, step:, attempts:, original_error: nil)
      super(message)
      @step_name = step
      @attempts = attempts
      @original_error = original_error
    end
  end
end
