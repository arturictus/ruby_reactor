# frozen_string_literal: true

module RubyReactor
  module Template
    class Value < Base
      attr_reader :value

      def initialize(value)
        @value = value
      end

      def resolve(context)
        @value
      end

      def inspect
        "value(#{@value.inspect})"
      end
    end
  end
end