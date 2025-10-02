# frozen_string_literal: true

module RubyReactor
  module Dsl
    class StepBuilder
      include RubyReactor::Dsl::TemplateHelpers

      attr_accessor :name, :impl, :arguments, :run_block, :compensate_block, :undo_block
      attr_accessor :conditions, :guards, :dependencies

      def initialize(name, impl = nil)
        @name = name
        @impl = impl
        @arguments = {}
        @run_block = nil
        @compensate_block = nil
        @undo_block = nil
        @conditions = []
        @guards = []
        @dependencies = []
      end

      def argument(name, source, transform: nil)
        @arguments[name] = {
          source: source,
          transform: transform
        }
      end

      def run(&block)
        @run_block = block
      end

      def compensate(&block)
        @compensate_block = block
      end

      def undo(&block)
        @undo_block = block
      end

      def where(&predicate)
        @conditions << predicate
      end

      def guard(&guard_fn)
        @guards << guard_fn
      end

      def wait_for(*step_names)
        @dependencies.concat(step_names)
      end

      def build
        step_config = {
          name: @name,
          impl: @impl,
          arguments: @arguments,
          run_block: @run_block,
          compensate_block: @compensate_block,
          undo_block: @undo_block,
          conditions: @conditions,
          guards: @guards,
          dependencies: @dependencies
        }

        RubyReactor::Dsl::StepConfig.new(step_config)
      end
    end

    class StepConfig
      attr_reader :name, :impl, :arguments, :run_block, :compensate_block, :undo_block
      attr_reader :conditions, :guards, :dependencies

      def initialize(config)
        @name = config[:name]
        @impl = config[:impl]
        @arguments = config[:arguments] || {}
        @run_block = config[:run_block]
        @compensate_block = config[:compensate_block]
        @undo_block = config[:undo_block]
        @conditions = config[:conditions] || []
        @guards = config[:guards] || []
        @dependencies = config[:dependencies] || []
      end

      def has_impl?
        !@impl.nil?
      end

      def has_run_block?
        !@run_block.nil?
      end

      def should_run?(context)
        @conditions.all? { |condition| condition.call(context) } &&
          @guards.all? { |guard| guard.call(context) }
      end
    end
  end
end