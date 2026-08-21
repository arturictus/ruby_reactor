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
          parent_name = reactor.name

          full_name = "#{parent_name}::#{step_name_camel}"
          @composed_reactor_class.define_singleton_method(:name) { full_name }
          RubyReactor::Registry.register(full_name, @composed_reactor_class)
        end
        @reactor = reactor
        @argument_mappings = {}
        @retry_config = {}
      end

      def argument(composed_input_name, source)
        @argument_mappings[composed_input_name] = source
      end

      # FR-003: `compose`'s `async` set the very same per-step hand-off flag the
      # step DSL's did, so it goes with it. The exact migration is
      # `background before: :<this compose step>` — that reproduces the old
      # semantics precisely (this step and everything after it move to the
      # worker) without the author having to identify a predecessor step.
      def async(*)
        raise RubyReactor::Error::DeprecatedDslError.new(
          "`async` inside a `compose` block has been removed (it set the same ambiguous per-step " \
          "hand-off flag as `step`'s). Use `background before: :#{@name}` on the reactor to move " \
          ":#{@name} and every step after it to a worker — that reproduces the old behavior exactly. " \
          "For a nested reactor that should run INDEPENDENTLY of this one, use " \
          "`async_reactor :#{@name}, #{@composed_reactor_class&.name || "ChildReactor"}` instead; " \
          "for one step's worth of work, `async_step`.",
          step: @name
        )
      end

      def retries(max_attempts: 3, backoff: :exponential, base_delay: 1)
        @retry_config = {
          max_attempts: max_attempts,
          backoff: backoff,
          base_delay: base_delay
        }
      end

      def build
        warn_if_child_has_ordered_lock!
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

      # An inline compose child is a real reactor class, so it can declare its
      # own hand-off point — delegate rather than making inline children the one
      # place `background` is unavailable.
      def background(**kwargs)
        ensure_composed_reactor_class!
        @composed_reactor_class.background(**kwargs)
      end

      private

      # Composed children bypass `Reactor#run`, so `assign_ordered_lock_nonce!`
      # never fires for them — their `with_ordered_lock` declaration is silently
      # ignored. Surface this at class load so users don't expect ordering
      # enforcement that isn't happening. Nested ordered-lock sequences must be
      # invoked as top-level `Reactor.run` to participate.
      def warn_if_child_has_ordered_lock!
        return unless @composed_reactor_class
        return unless @composed_reactor_class.respond_to?(:ordered_lock_config)
        return unless @composed_reactor_class.ordered_lock_config

        parent_name = @reactor&.name || "<anonymous>"
        child_name = @composed_reactor_class.name || "<anonymous>"
        RubyReactor.configuration.logger.warn(
          "RubyReactor: `with_ordered_lock` on #{child_name} is ignored when " \
          "composed by #{parent_name}##{@name}. Nested ordered-lock sequences " \
          "are independent and must run via top-level `Reactor.run` to be enforced."
        )
      end

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
