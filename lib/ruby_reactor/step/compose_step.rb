# frozen_string_literal: true

module RubyReactor
  module Step
    class ComposeStep
      include RubyReactor::Step

      attr_reader :composed_reactor_class, :argument_mappings

      def initialize(composed_reactor_class, argument_mappings = {})
        @composed_reactor_class = composed_reactor_class
        @argument_mappings = argument_mappings
      end

      def self.run(arguments, context)
        # Extract the composed reactor class and argument mappings from arguments
        composed_reactor = arguments[:composed_reactor_class]
        mappings = arguments[:argument_mappings] || {}

        # Check if we have a stored context for this step (from a previous retry)
        step_name = context.current_step
        composed_data = context.composed_contexts[step_name]
        child_context = composed_data ? composed_data[:context] : nil

        unless child_context
          # Build inputs for the composed reactor by resolving argument mappings
          composed_inputs = build_composed_inputs(mappings, context)

          # Create new context
          child_context = RubyReactor::Context.new(composed_inputs, composed_reactor)
        end

        # Link contexts
        child_context.parent_context = context
        child_context.root_context = context.root_context || context

        # Propagate test mode
        child_context.test_mode = context.test_mode

        # Propagate inline_async_execution
        child_context.inline_async_execution = context.inline_async_execution

        # Store the child context in composed_contexts BEFORE execution
        context.composed_contexts[step_name] = {
          name: step_name,
          type: :composed,
          context: child_context
        }

        # Execute the composed reactor
        executor = RubyReactor::Executor.new(composed_reactor, {}, child_context)

        # If we are resuming (child_context existed), we need to resume execution
        if composed_data && child_context.current_step
          executor.resume_execution
        else
          executor.execute
        end

        result = executor.result

        # Update the stored context (though it should be the same object)
        context.composed_contexts[step_name] = {
          name: step_name,
          type: :composed,
          context: child_context
        }

        # Handle async results - if the composed reactor is async, we need to return the async result
        return result if result.is_a?(RubyReactor::AsyncResult)

        # Handle retry queued results - bubble up
        return result if result.is_a?(RubyReactor::RetryQueuedResult)

        # For sync results, wrap in Success/Failure based on the result type
        if result.success?
          RubyReactor.Success(result.value)
        else
          RubyReactor.Failure(result.error)
        end
      end

      def self.compensate(_reason, _arguments, _context)
        # TODO: Implement proper compensation for composed reactors
        # This requires tracking the execution state of the composed reactor
        # and being able to trigger compensation on its completed steps.
        # For now, we assume the composed reactor handles its own compensation
        # or that compensation is not needed for composed steps.

        RubyReactor.Success()
      end

      class << self
        private

        def build_composed_inputs(mappings, context)
          inputs = {}

          mappings.each do |composed_input_name, source|
            value = source.resolve(context)
            inputs[composed_input_name] = value
          end

          inputs
        end
      end
    end
  end
end
