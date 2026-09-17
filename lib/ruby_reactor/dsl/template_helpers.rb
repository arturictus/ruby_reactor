# frozen_string_literal: true

module RubyReactor
  module Dsl
    module TemplateHelpers
      include RubyReactor::StepSignals

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

      # Make Success, Failure, Halt, and Skipped available in DSL contexts
      # rubocop:disable Naming/MethodName
      def Success(value = nil)
        # rubocop:enable Naming/MethodName
        RubyReactor.Success(value)
      end

      # rubocop:disable Naming/MethodName
      def Failure(...)
        # rubocop:enable Naming/MethodName
        RubyReactor.Failure(...)
      end

      # rubocop:disable Naming/MethodName
      def Halt(reason: nil, **kwargs)
        # rubocop:enable Naming/MethodName
        RubyReactor.Halt(reason: reason, **kwargs)
      end

      # rubocop:disable Naming/MethodName
      def Skipped(...)
        # rubocop:enable Naming/MethodName
        RubyReactor.Skipped(...)
      end
    end
  end
end
