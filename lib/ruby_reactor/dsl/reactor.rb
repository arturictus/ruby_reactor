# frozen_string_literal: true

module RubyReactor
  module Dsl
    module Reactor
      def self.included(base)
        base.extend(ClassMethods)
        base.instance_variable_set(:@inputs, {})
        base.instance_variable_set(:@steps, {})
        base.instance_variable_set(:@return_step, nil)
        base.instance_variable_set(:@middlewares, [])
        base.instance_variable_set(:@input_validations, {})
      end

      module ClassMethods
        include RubyReactor::Dsl::TemplateHelpers

        def inputs
          @inputs ||= {}
        end

        def steps
          @steps ||= {}
        end

        def return_step
          @return_step
        end

        def middlewares
          @middlewares ||= []
        end

        def input_validations
          @input_validations ||= {}
        end

        def input(name, transform: nil, description: nil, validate: nil, optional: false, &validation_block)
          inputs[name] = {
            transform: transform,
            description: description,
            optional: optional
          }

          # Handle validation
          return unless validate || validation_block

          validator = create_input_validator(validation_block || validate)
          input_validations[name] = validator
        end

        def step(name, impl = nil, &block)
          builder = RubyReactor::Dsl::StepBuilder.new(name, impl)

          builder.instance_eval(&block) if block_given?

          step_config = builder.build
          steps[name] = step_config
          step_config
        end

        def returns(step_name)
          @return_step = step_name
        end

        # Alias for backward compatibility
        alias return returns

        def middleware(middleware_class)
          middlewares << middleware_class
        end

        def validate_inputs(inputs_hash)
          errors = {}

          input_validations.each do |input_name, validator|
            # Skip validation if input is optional and not provided
            next if inputs[input_name][:optional] && !inputs_hash.key?(input_name)

            input_data = inputs_hash[input_name]
            # Validate by wrapping the individual input in a hash with its name
            result = validator.call({ input_name => input_data })

            errors.merge!(result.error.field_errors) if result.failure? && result.error.respond_to?(:field_errors)
          end

          if errors.empty?
            RubyReactor.Success(inputs_hash)
          else
            error = RubyReactor::Error::InputValidationError.new(errors)
            RubyReactor.Failure(error)
          end
        end

        # Validation helper methods
        def build_validation_schema(&block)
          check_dry_validation_available!
          RubyReactor::Validation::SchemaBuilder.build_from_block(&block)
        end

        def create_input_validator(schema_or_block)
          check_dry_validation_available!

          schema = case schema_or_block
                   when Proc
                     build_validation_schema(&schema_or_block)
                   else
                     schema_or_block
                   end

          RubyReactor::Validation::InputValidator.new(schema)
        end

        # Entry point for running the reactor
        def run(inputs = {})
          reactor = new
          reactor.run(inputs)
        end

        def call(inputs = {})
          run(inputs)
        end

        private

        def check_dry_validation_available!
          return if defined?(Dry::Schema)

          raise LoadError,
                "dry-validation gem is required for validation features. Add 'gem \"dry-validation\"' to your Gemfile."
        end
      end
    end
  end
end
