# frozen_string_literal: true

module RubyReactor
  module Error
    # A step read an input it can't read (a typo, or a name it never
    # declared). It fails the same way on every attempt, so it never retries.
    class UndeclaredInputError < NoMethodError
      def retryable?
        false
      end
    end
  end
end
