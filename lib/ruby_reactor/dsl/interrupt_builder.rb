# frozen_string_literal: true

module RubyReactor
  module Dsl
    class InterruptBuilder < StepBuilder
      def initialize(name, reactor = nil)
        super(name, nil, reactor)
        @correlation_id_block = nil
        @timeout_config = nil
        @validation_schema = nil
      end

      def correlation_id(&block)
        @correlation_id_block = block
      end

      def timeout(seconds, strategy: :lazy)
        @timeout_config = { duration: seconds, strategy: strategy }
      end

      def validate(&block)
        check_dry_validation_available!
        @validation_schema = build_validation_schema(&block)
      end

      def build
        step_config = {
          name: @name,
          correlation_id_block: @correlation_id_block,
          timeout_config: @timeout_config,
          validation_schema: @validation_schema,
          dependencies: @dependencies,
          async: false, # Interrupts are effectively boundaries, not async jobs themselves (until resumed)
          conditions: @conditions,
          guards: @guards
        }

        RubyReactor::Dsl::InterruptStepConfig.new(step_config)
      end
    end
  end
end
