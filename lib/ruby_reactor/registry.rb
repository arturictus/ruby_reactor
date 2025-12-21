# frozen_string_literal: true

require "concurrent"

module RubyReactor
  # Registry for dynamically created reactor classes (e.g. from inline map/compose)
  # This avoids polluting the global constant namespace with runtime-generated constants.
  class Registry
    @reactors = Concurrent::Map.new

    class << self
      def register(name, klass)
        @reactors[name] = klass
      end

      def find(name)
        @reactors[name]
      end

      def clear!
        @reactors.clear
      end
    end
  end
end
