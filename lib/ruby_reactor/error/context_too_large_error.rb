# frozen_string_literal: true

module RubyReactor
  module Error
    class ContextTooLargeError < Base
      def initialize(message)
        super("Context size exceeds limits: #{message}")
      end
    end
  end
end
