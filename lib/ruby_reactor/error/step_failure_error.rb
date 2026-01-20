# frozen_string_literal: true

module RubyReactor
  module Error
    class StepFailureError < Base
      attr_reader :step_arguments, :exception_class

      def initialize(message, step: nil, context: nil, original_error: nil, step_arguments: {}, exception_class: nil)
        super(message, step: step, context: context, original_error: original_error)
        @step_arguments = step_arguments
        @exception_class = exception_class
      end

      def retryable?
        true
      end
    end
  end
end
