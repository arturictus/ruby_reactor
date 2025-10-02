# frozen_string_literal: true

module RubyReactor
  module Template
    class Input < Base
      attr_reader :name, :path

      def initialize(name, path = nil)
        @name = name
        @path = path
      end

      def resolve(context)
        value = context.get_input(@name)
        return nil if value.nil?

        if @path
          extract_path(value, @path)
        else
          value
        end
      end

      def inspect
        if @path
          "input(:#{@name}, #{@path.inspect})"
        else
          "input(:#{@name})"
        end
      end

      private

      def extract_path(value, path)
        case path
        when Symbol
          value[path] if value.respond_to?(:[]) 
        when String
          path.split('.').reduce(value) { |v, key| v&.send(:[], key) }
        when Array
          path.reduce(value) { |v, key| v&.send(:[], key) }
        else
          value.send(path) if value.respond_to?(path)
        end
      end
    end
  end
end