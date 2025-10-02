# frozen_string_literal: true

module RubyReactor
  module Template
    class Input < Base
      attr_reader :name, :path

      def initialize(name, path = nil)
        super()
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
        if path.is_a?(Symbol) && value.respond_to?(:[])
          value[path]
        elsif path.is_a?(String)
          path.split(".").reduce(value) { |v, key| v&.send(:[], key) }
        elsif path.is_a?(Array)
          path.reduce(value) { |v, key| v&.send(:[], key) }
        elsif value.respond_to?(path)
          value.send(path)
        end
      end
    end
  end
end
