# frozen_string_literal: true

module RubyReactor
  module Dsl
    class ComposeBuilder
      include RubyReactor::Dsl::TemplateHelpers

      attr_accessor :name, :composed_reactor_class, :argument_mappings

      def initialize(name, composed_reactor_class = nil, reactor = nil, &block)
        @name = name
        @composed_reactor_class = composed_reactor_class || (block ? Class.new(RubyReactor::Reactor) : nil)
        if @composed_reactor_class && @composed_reactor_class.name.nil? && reactor
          step_name_camel = name.to_s.split("_").map(&:capitalize).join

          # Define the class as a constant under the parent reactor to give it a proper name
          # This ensures it can be serialized and deserialized correctly
          if reactor.const_defined?(step_name_camel, false)
            # If it's already defined, we might simply use it, or check if it matches.
            # For now, we assume it's the correct one or we overwrite it if allowed.
            # To be safe against re-definition warnings:
            # reactor.side_load_step_class? No.
            # Just silencing warning if needed, but let's try direct set first.
            # Actually, RSpec might perform the definition multiple times if the class is reloaded or if specs share state step?
            # Ideally we skip if already set? But what if the definition changed?
            # Since this is "inline", a new anonymous class is created every time `compose` is called.
            # If we don't overwrite the constant, we use the old one (which matches the old anonymous class).
            # But the new anonymous class `Class.new` is what we want to use.
            reactor.send(:remove_const, step_name_camel)
          end
          reactor.const_set(step_name_camel, @composed_reactor_class)
        end
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
