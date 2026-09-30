# frozen_string_literal: true

module RubyReactor
  module Error
    # A step's `argument` source, `transform` or result path raised. The step's
    # body never started, so it is never compensated; completed steps are
    # undone (008 R-06). The same inputs fail the same way, so never retried.
    class ArgumentResolutionError < Base
      attr_reader :exception_class

      def initialize(message, step:, original_error:, context: nil)
        super(message, step: step, context: context, original_error: original_error)
        @exception_class = original_error.class.name
      end

      def retryable? = false
    end
  end
end
