# frozen_string_literal: true

module RubyReactor
  module Error
    class DeserializationError < Base
      def initialize(message)
        super("Context deserialization failed: #{message}")
      end
    end
  end
end