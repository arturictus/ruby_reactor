# frozen_string_literal: true

module RubyReactor
  module Error
    # A step's `where`/`guard` raised. Same rule as ArgumentResolutionError:
    # the body never started, so the step is not compensated (008 R-06).
    class ConditionError < Base
      attr_reader :exception_class

      def initialize(message, step:, original_error:, context: nil)
        super(message, step: step, context: context, original_error: original_error)
        @exception_class = original_error.class.name
      end

      def retryable? = false
    end
  end
end
