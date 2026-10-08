# frozen_string_literal: true

module RubyReactor
  module Dsl
    class MapBuilder
      include RubyReactor::Dsl::TemplateHelpers
      include RubyReactor::Dsl::DefinitionWarnings

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
        @atomic = true # Default: every element succeeds, or none is kept
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
      # element jobs one throw enqueues (back pressure), forward and rollback;
      # without it, `Map::DEFAULT_BATCH_SIZE` (50) does. A fan-out map is a
      # hand-off point: the reactor stops at the map and resumes in a worker
      # once the collector has every element's outcome.
      def fan_out(enabled = true, batch_size: nil)
        @fan_out = enabled
        self.batch_size(batch_size) unless batch_size.nil?
      end

      # `async` on a map named element fan-out with the word that now means
      # `async_step` / `async_reactor` — independent units the reactor does not
      # stop for. A fan-out map does stop the reactor, so it gets its own word.
      def async(*)
        raise RubyReactor::Error::DeprecatedDslError.new(
          "`async` inside a `map` block has been removed: it read as `async_step`/`async_reactor`, which " \
          "dispatch independent units, whereas a fan-out map hands the reactor off until every element " \
          "finishes. Use `fan_out` instead (`fan_out batch_size: N` for back pressure) — note this also " \
          "changes worker dispatch: each element now runs in its own background worker rather than being " \
          "suppressed inline by `inline_async_execution` as the old `async true` was.",
          step: @name
        )
      end

      def strict_ordering(enabled = true)
        @strict_ordering = enabled
      end

      def batch_size(size)
        unless size.is_a?(Integer) && size.positive?
          raise RubyReactor::Error::ValidationError.new(
            "`batch_size` must be a positive Integer, got #{size.inspect}",
            step: @name
          )
        end

        @batch_size = size
      end

      def collect(&block)
        @collect_block = block
      end

      # One call that rolls back every completed element (010 US7), instead of
      # replaying each element's own undos: a bulk refund, a batch delete. The
      # block gets a lazy Enumerable of the completed elements' results, in
      # index order, on every rollback of the map.
      def undo_all(&block)
        raise RubyReactor::Error::ValidationError.new("map :#{@name} undo_all needs a block", step: @name) unless block
        if @undo_all_block
          raise RubyReactor::Error::ValidationError.new("map :#{@name} declares undo_all twice", step: @name)
        end

        @undo_all_block = block
      end

      # On (the default), the map succeeds only if every element does: the
      # first element failure fails it, no new element starts, and every
      # completed element is rolled back. Off, it completes with every
      # element's outcome; a failed element rolls itself back, the others are
      # kept.
      def atomic(enabled = true)
        @atomic_declared = true
        @atomic = enabled
      end

      # The old name for `atomic` (009 R-11), which read as "stop early".
      def fail_fast(enabled = true)
        @fail_fast_site = caller_locations(1, 1).first
        @atomic = enabled
        warn_deprecation(@fail_fast_site, "map :#{@name} declares fail_fast. Use atomic (same meaning).")
      end

      def build
        if @atomic_declared && @fail_fast_site
          raise RubyReactor::Error::ValidationError.new(
            "map :#{@name} declares both fail_fast and atomic; declare only atomic", step: @name
          )
        end

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
            atomic: { source: RubyReactor::Template::Value.new(@atomic) },
            fan_out: { source: RubyReactor::Template::Value.new(@fan_out) },
            **undo_all_argument
          },
          run_block: nil,
          compensate_block: nil,
          undo_block: nil,
          dependencies: dependencies.uniq,
          args_validator: nil,
          output_validator: nil
        }
      end

      # Read at rollback from this declaration (`MapStep#undo_all_block`).
      def undo_all_argument
        @undo_all_block ? { undo_all_block: { source: RubyReactor::Template::Value.new(@undo_all_block) } } : {}
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
