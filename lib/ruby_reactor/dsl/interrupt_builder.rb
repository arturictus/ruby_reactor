# frozen_string_literal: true

module RubyReactor
  module Dsl
    class InterruptBuilder < StepBuilder
      def initialize(name, reactor = nil)
        super(name, nil, reactor)
        @correlation_id_block = nil
        @timeout_config = nil
        @validation_schema = nil
        @max_attempts = 1
      end

      def max_attempts(count)
        @max_attempts = count
      end

      def correlation_id(&block)
        @correlation_id_block = block
      end

      def timeout(seconds, strategy: :lazy)
        @timeout_config = { duration: seconds, strategy: strategy }
      end

      # Validate the resume payload. Accepts a block (schema DSL) or a pre-built
      # dry-schema. Payloads are multi-field hashes, so the block stays primary.
      def validate_payload(schema = nil, &block)
        check_dry_validation_available!
        @validation_schema =
          if block
            build_validation_schema(&block)
          elsif schema
            RubyReactor::Validation::SchemaBuilder.schema_for(schema)
          end
      end

      # Deprecated alias for {#validate_payload}.
      def validate(schema = nil, &block)
        unless @warned_validate
          @warned_validate = true
          warn "[RubyReactor] DEPRECATION: interrupt `validate` is deprecated; use `validate_payload` instead."
        end
        validate_payload(schema, &block)
      end

      def build
        step_config = {
          name: @name,
          correlation_id_block: @correlation_id_block,
          timeout_config: @timeout_config,
          validation_schema: @validation_schema,
          max_attempts: @max_attempts,
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
