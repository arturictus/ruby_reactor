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
        base.instance_variable_set(:@async, false)
        base.instance_variable_set(:@retry_defaults, { max_attempts: 3, backoff: :exponential, base_delay: 1 })
      end

      module ClassMethods
        include RubyReactor::Dsl::TemplateHelpers
        include RubyReactor::Dsl::ValidationHelpers

        require_relative "interrupt_builder"
        require_relative "interrupt_step_config"

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

        def async(async = true)
          @async = async
        end

        def async?
          @async ||= false
        end

        def retry_defaults(**kwargs)
          if kwargs.empty?
            @retry_defaults ||= { max_attempts: 1, backoff: :exponential, base_delay: 1 }
          else
            @retry_defaults = {
              max_attempts: kwargs[:max_attempts] || 1,
              backoff: kwargs[:backoff] || :exponential,
              base_delay: kwargs[:base_delay] || 1
            }
          end
        end

        # rubocop:disable Metrics/ParameterLists
        def input(name, transform: nil, description: nil, validate: nil, optional: false, redact: false,
                  &validation_block)
          # rubocop:enable Metrics/ParameterLists
          inputs[name] = {
            transform: transform,
            description: description,
            optional: optional,
            redact: redact
          }

          # Handle validation
          return unless validate || validation_block

          validator = create_input_validator(validation_block || validate)
          input_validations[name] = validator
        end

        def step(name, impl = nil, &block)
          builder = RubyReactor::Dsl::StepBuilder.new(name, impl, self)

          builder.instance_eval(&block) if block_given?

          step_config = builder.build
          steps[name] = step_config
          step_config
        end

        def compose(name, composed_reactor_class = nil, &block)
          builder = RubyReactor::Dsl::ComposeBuilder.new(name, composed_reactor_class, self, &block)

          builder.instance_eval(&block) if block_given?

          step_config = builder.build
          steps[name] = step_config
          step_config
        end

        def map(name, reactor_class = nil, &block)
          builder = RubyReactor::Dsl::MapBuilder.new(name, reactor_class, self, &block)

          builder.instance_eval(&block) if block_given?

          step_config = builder.build
          steps[name] = step_config
          step_config
        end

        def interrupt(name, &block)
          builder = RubyReactor::Dsl::InterruptBuilder.new(name, self)
          builder.instance_eval(&block) if block_given?

          step_config = builder.build
          steps[name] = step_config
          step_config
        end

        def returns(step_name = nil)
          @return_step = step_name if step_name
          @return_step
        end

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

        # Entry point for running the reactor
        def run(inputs = {})
          reactor = new
          reactor.run(inputs)
        end

        def call(inputs = {})
          run(inputs)
        end
      end
    end
  end
end
