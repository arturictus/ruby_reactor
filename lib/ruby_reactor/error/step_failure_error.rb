# frozen_string_literal: true

module RubyReactor
  module Error
    class StepFailureError < Base
      attr_reader :step_arguments

      def initialize(message, step: nil, context: nil, original_error: nil, step_arguments: {})
        super(message, step: step, context: context, original_error: original_error)
        @step_arguments = step_arguments
      end

      def retryable?
        true
      end
    end
  end
end
