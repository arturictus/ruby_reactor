# frozen_string_literal: true

module RubyReactor
  module Template
    class Result < Base
      attr_reader :step_name, :path

      def initialize(step_name, path = nil)
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