# frozen_string_literal: true

module RubyReactor
  module Template
    class Value < Base
      attr_reader :value

      def initialize(value)
        super()
        @value = value
      end

      def resolve(_context)
        @value
      end

      def inspect
        "value(#{@value.inspect})"
      end
    end
  end
end
