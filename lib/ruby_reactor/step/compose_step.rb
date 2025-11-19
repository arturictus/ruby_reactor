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

        # Build inputs for the composed reactor by resolving argument mappings
        composed_inputs = build_composed_inputs(mappings, context)

        # Create and run the composed reactor
        result = composed_reactor.run(composed_inputs)

        # Handle async results - if the composed reactor is async, we need to return the async result
        return result if result.is_a?(RubyReactor::AsyncResult)

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
