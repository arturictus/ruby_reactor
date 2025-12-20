# frozen_string_literal: true

module RubyReactor
  module Dsl
    class MapBuilder
      include RubyReactor::Dsl::TemplateHelpers

      attr_accessor :name, :mapped_reactor_class, :argument_mappings, :source_enumerable

      def initialize(name, mapped_reactor_class = nil, reactor = nil, &block)
        @name = name
        @mapped_reactor_class = mapped_reactor_class || (block ? Class.new(RubyReactor::Reactor) : nil)
        if @mapped_reactor_class && @mapped_reactor_class.name.nil?
          parent_name = reactor&.name || "Anonymous_#{reactor.object_id}"
          step_name_camel = name.to_s.split("_").map(&:capitalize).join
          pseudo_name = "#{parent_name}::#{step_name_camel}"
          @mapped_reactor_class.define_singleton_method(:name) { pseudo_name }
        end
        @reactor = reactor
        @argument_mappings = {}
        @async = false
        @strict_ordering = true
        @batch_size = nil
        @source_enumerable = nil
        @collect_block = nil
        @fail_fast = true # Default: stop on first error
      end

      def argument(mapped_input_name, source)
        @argument_mappings[mapped_input_name] = source
      end

      def source(enumerable)
        @source_enumerable = enumerable
      end

      def async(async = true, batch_size: nil)
        @async = async
        @batch_size = batch_size if batch_size
      end

      def strict_ordering(enabled = true)
        @strict_ordering = enabled
      end

      def batch_size(size)
        @batch_size = size
      end

      def collect(&block)
        @collect_block = block
      end

      def fail_fast(enabled = true)
        @fail_fast = enabled
      end

      def build
        dependencies = extract_dependencies_from_mappings
        dependencies << @source_enumerable.step_name if @source_enumerable.is_a?(RubyReactor::Template::Result)

        RubyReactor::Dsl::StepConfig.new(build_step_config(dependencies))
      end

      # Delegate step definition methods to the mapped reactor class
      def step(name, &block)
        ensure_mapped_reactor_class!
        @mapped_reactor_class.step(name, &block)
      end

      def returns(step_name)
        ensure_mapped_reactor_class!
        @mapped_reactor_class.returns(step_name)
      end
      alias return returns

      private

      def ensure_mapped_reactor_class!
        raise ArgumentError, "No block provided for inline map" unless @mapped_reactor_class
      end

      def build_step_config(dependencies)
        {
          name: @name,
          impl: RubyReactor::Step::MapStep,
          arguments: {
            mapped_reactor_class: { source: RubyReactor::Template::Value.new(@mapped_reactor_class) },
            argument_mappings: { source: RubyReactor::Template::Value.new(@argument_mappings) },
            source: { source: @source_enumerable },
            strict_ordering: { source: RubyReactor::Template::Value.new(@strict_ordering) },
            batch_size: { source: RubyReactor::Template::Value.new(@batch_size) },
            collect_block: { source: RubyReactor::Template::Value.new(@collect_block) },
            fail_fast: { source: RubyReactor::Template::Value.new(@fail_fast) },
            async: { source: RubyReactor::Template::Value.new(@async) }
          },
          run_block: nil,
          compensate_block: nil,
          undo_block: nil,
          conditions: [],
          guards: [],
          dependencies: dependencies.uniq,
          args_validator: nil,
          output_validator: nil,
          async: false # MapStep handles async internally via run_async
        }
      end

      def extract_dependencies_from_mappings
        dependencies = []
        @argument_mappings.each_value do |source|
          dependencies << source.step_name if source.is_a?(RubyReactor::Template::Result)
        end
        dependencies
      end
    end
  end
end
