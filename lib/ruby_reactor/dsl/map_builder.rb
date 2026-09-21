# frozen_string_literal: true

module RubyReactor
  module Dsl
    class MapBuilder
      include RubyReactor::Dsl::TemplateHelpers

      attr_accessor :name, :mapped_reactor_class, :argument_mappings, :source_enumerable

      def initialize(name, mapped_reactor_class = nil, reactor = nil, &block)
        @name = name
        @mapped_reactor_class = mapped_reactor_class || (block ? Class.new(RubyReactor::Reactor) : nil)
        if @mapped_reactor_class && @mapped_reactor_class.name.nil? && reactor
          map_name_camel = name.to_s.split("_").map(&:capitalize).join
          parent_name = reactor.name # Assuming reactor has a name method or is a class with a name.

          full_name = "#{parent_name}::#{map_name_camel}"
          @mapped_reactor_class.define_singleton_method(:name) { full_name }
          RubyReactor::Registry.register(full_name, @mapped_reactor_class)
        end
        @reactor = reactor
        @argument_mappings = {}
        @fan_out = false
        @strict_ordering = true
        @batch_size = nil
        @source_enumerable = nil
        @collect_block = nil
        @fail_fast = true # Default: stop on first error
      end

      def argument(mapped_input_name, source)
        @argument_mappings[mapped_input_name] = source
      end

      def source(enumerable = nil, &block)
        @source_enumerable = if block
                               RubyReactor::Template::DynamicSource.new(@argument_mappings, &block)
                             else
                               enumerable
                             end
      end

      # Run every element as its own background job. `batch_size` caps how many
      # element jobs are enqueued at a time (back pressure); without it the whole
      # source fans out at once. A fan-out map is a hand-off point: the reactor
      # stops at the map and resumes in a worker once the collector has every
      # element's outcome.
      def fan_out(enabled = true, batch_size: nil)
        @fan_out = enabled
        @batch_size = batch_size if batch_size
      end

      # `async` on a map named element fan-out with the word that now means
      # `async_step` / `async_reactor` — independent units the reactor does not
      # stop for. A fan-out map does stop the reactor, so it gets its own word.
      def async(*)
        raise RubyReactor::Error::DeprecatedDslError.new(
          "`async` inside a `map` block has been removed: it read as `async_step`/`async_reactor`, which " \
          "dispatch independent units, whereas a fan-out map hands the reactor off until every element " \
          "finishes. Use `fan_out` instead (`fan_out batch_size: N` for back pressure) — identical behavior.",
          step: @name
        )
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
            fan_out: { source: RubyReactor::Template::Value.new(@fan_out) }
          },
          run_block: nil,
          compensate_block: nil,
          undo_block: nil,
          conditions: [],
          guards: [],
          dependencies: dependencies.uniq,
          args_validator: nil,
          output_validator: nil
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
