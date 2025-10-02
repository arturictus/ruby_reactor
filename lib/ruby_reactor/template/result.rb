# frozen_string_literal: true

module RubyReactor
  module Template
    class Result < Base
      attr_reader :step_name, :path

      def initialize(step_name, path = nil)
        super()
        @step_name = step_name
        @path = path
      end

      def resolve(context)
        value = context.get_result(@step_name)
        return nil if value.nil?

        if @path
          extract_path(value, @path)
        else
          value
        end
      end

      def inspect
        if @path
          "result(:#{@step_name}, #{@path.inspect})"
        else
          "result(:#{@step_name})"
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
