# frozen_string_literal: true

module RubyReactor
  module Error
    class StepFailureError < Base
      attr_reader :step_arguments, :exception_class, :validation_errors

      # rubocop:disable Metrics/ParameterLists
      def initialize(message, step: nil, context: nil, original_error: nil, step_arguments: {}, exception_class: nil,
                     validation_errors: nil)
        # rubocop:enable Metrics/ParameterLists
        super(message, step: step, context: context, original_error: original_error)
        @step_arguments = step_arguments
        @exception_class = exception_class
        @validation_errors = validation_errors
      end

      def retryable?
        true
      end
    end
  end
end
