# frozen_string_literal: true

module RubyReactor
  class MaxRetriesExhaustedFailure < Failure
    attr_reader :attempts, :original_error

    # rubocop:disable Metrics/ParameterLists
    def initialize(message, step:, attempts:, original_error: nil,
                   inputs: {}, backtrace: nil, redact_inputs: [],
                   reactor_name: nil, step_arguments: {})
      # rubocop:enable Metrics/ParameterLists
      super(message,
            step_name: step, inputs: inputs, backtrace: backtrace,
            redact_inputs: redact_inputs, reactor_name: reactor_name, step_arguments: step_arguments)
      @attempts = attempts
      @original_error = original_error
    end
  end
end
