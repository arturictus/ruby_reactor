# frozen_string_literal: true

module RubyReactor
  module Dsl
    class ComposeBuilder
      include RubyReactor::Dsl::TemplateHelpers

      attr_accessor :name, :composed_reactor_class, :argument_mappings

      def initialize(name, composed_reactor_class = nil, reactor = nil, &block)
        @name = name
        @composed_reactor_class = composed_reactor_class || (block ? Class.new(RubyReactor::Reactor) : nil)
        @reactor = reactor
        @argument_mappings = {}
        @async = false
        @retry_config = {}
      end

      def argument(composed_input_name, source)
        @argument_mappings[composed_input_name] = source
      end

      def async(async = true)
        @async = async
      end

      def retries(max_attempts: 3, backoff: :exponential, base_delay: 1)
        @retry_config = {
          max_attempts: max_attempts,
          backoff: backoff,
          base_delay: base_delay
        }
      end

      def build
        dependencies = extract_dependencies_from_mappings

        step_config = {
          name: @name,
          impl: RubyReactor::Step::ComposeStep,
          arguments: {
            composed_reactor_class: { source: RubyReactor::Template::Value.new(@composed_reactor_class) },
            argument_mappings: { source: RubyReactor::Template::Value.new(@argument_mappings) }
          },
          run_block: nil,
          compensate_block: nil,
          undo_block: nil,
          conditions: [],
          guards: [],
          dependencies: dependencies,
          args_validator: nil,
          output_validator: nil,
          async: @async,
          retry_config: @retry_config.empty? ? (@reactor&.retry_defaults || {}) : @retry_config
        }

        RubyReactor::Dsl::StepConfig.new(step_config)
      end

      # Delegate step definition methods to the composed reactor class
      def step(name, &block)
        ensure_composed_reactor_class!
        @composed_reactor_class.step(name, &block)
      end

      def compose(name, reactor_class = nil, &block)
        ensure_composed_reactor_class!
        @composed_reactor_class.compose(name, reactor_class, &block)
      end

      private

      def ensure_composed_reactor_class!
        raise ArgumentError, "No block provided for inline compose" unless @composed_reactor_class
      end

      def extract_dependencies_from_mappings
        dependencies = []
        @argument_mappings.each_value do |source|
          dependencies << source.step_name if source.is_a?(RubyReactor::Template::Result)
        end
        dependencies.uniq
      end
    end
  end
end
