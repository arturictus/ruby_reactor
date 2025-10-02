# frozen_string_literal: true

module RubyReactor
  module Dsl
    module TemplateHelpers
      def input(name, path = nil)
        RubyReactor::Template::Input.new(name, path)
      end

      def result(step_name, path = nil)
        RubyReactor::Template::Result.new(step_name, path)
      end

      def value(val)
        RubyReactor::Template::Value.new(val)
      end

      def element(map_name, path = nil)
        RubyReactor::Template::Element.new(map_name, path)
      end

      # Make Success and Failure available in DSL contexts
      def Success(value = nil)
        RubyReactor.Success(value)
      end

      def Failure(error)
        RubyReactor.Failure(error)
      end
    end
  end
end
