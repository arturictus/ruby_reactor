# frozen_string_literal: true

module RubyReactor
  module Error
    class Base < StandardError
      attr_reader :step, :context, :original_error

      def initialize(message, step: nil, context: nil, original_error: nil)
        super(message)
        @step = step
        @context = context
        @original_error = original_error
      end
    end
  end
end
