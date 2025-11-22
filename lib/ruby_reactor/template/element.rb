# frozen_string_literal: true

module RubyReactor
  module Template
    class Element < Base
      attr_reader :map_name, :path

      def initialize(map_name, path = nil)
        super()
        @map_name = map_name
        @path = path
      end

      def resolve(_context)
        # Element resolution happens inside MapStep, not generic resolve
        # But if called in wrong context, raise error
        raise RubyReactor::Error::DependencyError, "element() can only be used within a map argument mapping"
      end

      def inspect
        "element(:#{@map_name}#{", #{@path.inspect}" if @path})"
      end
    end
  end
end
