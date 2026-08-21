# frozen_string_literal: true

module RubyReactor
  module Dsl
    # Builds the `async_reactor` dispatch step. Same `argument` mapping shape as
    # `ComposeBuilder`, but deliberately NOT a subclass of it: `compose`'s
    # builder warns that a child's `with_ordered_lock` is ignored (true for an
    # inline child, which bypasses `Reactor#run`) whereas an `async_reactor`
    # child is dispatched through the full pre-enqueue sequence and DOES get its
    # ordering nonce (FR-016).
    class AsyncReactorBuilder
      include RubyReactor::Dsl::TemplateHelpers

      attr_accessor :name, :child_reactor_class, :argument_mappings

      def initialize(name, child_reactor_class, reactor = nil)
        @name = name
        @child_reactor_class = child_reactor_class
        @reactor = reactor
        @argument_mappings = {}
        @retry_config = {}
      end

      def argument(child_input_name, source)
        @argument_mappings[child_input_name] = source
      end

      def retries(max_attempts: 3, backoff: :exponential, base_delay: 1)
        @retry_config = { max_attempts: max_attempts, backoff: backoff, base_delay: base_delay }
      end

      def build
        RubyReactor::Dsl::StepConfig.new(
          async_dispatch: :reactor,
          name: @name,
          impl: RubyReactor::Step::AsyncReactorStep,
          arguments: {
            async_reactor_class: { source: RubyReactor::Template::Value.new(@child_reactor_class) },
            argument_mappings: { source: RubyReactor::Template::Value.new(@argument_mappings) }
          },
          run_block: nil,
          # No compensate/undo: the child is deliberately outside the parent's
          # compensation graph (FR-009). Compensation is opt-in, via a later step
          # that reads `result(:name)` and decides to fail.
          compensate_block: nil,
          undo_block: nil,
          conditions: [],
          guards: [],
          dependencies: dependencies_from_mappings,
          args_validator: nil,
          output_validator: nil,
          retry_config: @retry_config.empty? ? (@reactor&.retry_defaults || {}) : @retry_config
        )
      end

      private

      def dependencies_from_mappings
        @argument_mappings.each_value
                          .select { |source| source.is_a?(RubyReactor::Template::Result) }
                          .map(&:step_name)
                          .uniq
      end
    end
  end
end
