# frozen_string_literal: true

module RubyReactor
  module Dsl
    # Builds the `async_reactor` dispatch step. Same `argument` mapping shape as
    # `ComposeBuilder`, but deliberately NOT a subclass of it: `compose`'s
    # builder warns that a child's `with_ordered_lock` is ignored (true for an
    # inline child, which bypasses `Reactor#run`) whereas an `async_reactor`
    # child is dispatched through the full pre-enqueue sequence and DOES get its
    # ordering nonce.
    class AsyncReactorBuilder
      include RubyReactor::Dsl::TemplateHelpers

      attr_accessor :name, :child_reactor_class, :argument_mappings

      def initialize(name, child_reactor_class, reactor = nil)
        @name = name
        @child_reactor_class = child_reactor_class
        @reactor = reactor
        @argument_mappings = {}
      end

      def argument(child_input_name, source)
        @argument_mappings[child_input_name] = source
      end

      # A parent never retries a nested reactor as a whole (008 R-14): the
      # child owns its steps' retries. Kept as a stub to name the replacement.
      def retries(*)
        raise RubyReactor::Error::DeprecatedDslError.new(
          "`retries` on an `async_reactor` has been removed: a parent never retries a nested " \
          "reactor as a whole. Declare `retries` on :#{@name}'s child reactor's own steps " \
          "(`retries max_attempts: 3` in the step block or the step class); the child retries them itself.",
          step: @name
        )
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
          # compensation graph. Compensation is opt-in, via a later step
          # that reads `result(:name)` and decides to fail.
          compensate_block: nil,
          undo_block: nil,
          dependencies: dependencies_from_mappings,
          args_validator: nil,
          output_validator: nil
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
