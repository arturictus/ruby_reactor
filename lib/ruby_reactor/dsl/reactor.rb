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
        base.instance_variable_set(:@background_handoff, nil)
        base.instance_variable_set(:@retry_defaults, { max_attempts: 3, backoff: :exponential, base_delay: 1 })
      end

      module ClassMethods
        include RubyReactor::Dsl::TemplateHelpers
        include RubyReactor::Dsl::ValidationHelpers
        include RubyReactor::Dsl::AsyncMacros

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

        # Whole-reactor `async true` is gone: it named the same idea as
        # `background`'s cut point with a different word, right next to the
        # new `async_step`/`async_reactor` macros whose names mean something
        # else entirely. `async?` (the reader) lives in `AsyncMacros`, driven
        # off `background_handoff`.
        def async(*)
          raise RubyReactor::Error::DeprecatedDslError,
                "`async true` on a reactor has been removed: it named the same idea as `background`'s cut " \
                "point with a different word, and read confusingly next to the `async_step`/`async_reactor` " \
                "step macros. Use `background all: true` instead — identical behavior, including validating " \
                "inputs inside the worker."
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
        def input(name, type = nil, transform: nil, description: nil, validate: nil, optional: false, redact: false,
                  **predicates, &block)
          # rubocop:enable Metrics/ParameterLists
          inputs[name] = {
            transform: transform,
            description: description,
            optional: optional,
            redact: redact
          }

          validator = build_input_validator_for(name, type, optional, validate, predicates, &block)
          input_validations[name] = validator if validator
        end

        # Dispatch across the layered `input` forms:
        #   Form 3 — pre-built schema / contract (`validate:`)
        #   Form 2 — block bound to the value macro (`do |i| ... end`)
        #   legacy — single-key schema block (`do required(:name)... end`)
        #   Form 1 / 1b — inline scalar or class type
        #   Form 0 — declaration only (no validator)
        def build_input_validator_for(name, type, optional, validate, predicates, &block)
          if validate
            create_input_validator(validate)
          elsif block
            if block.arity.nonzero?
              build_macro_validator(name, optional, &block)
            else
              warn_deprecated_input_block
              create_input_validator(block)
            end
          elsif type || predicates.any?
            build_inline_validator(name, type, optional, predicates)
          end
        end
        private :build_input_validator_for

        def warn_deprecated_input_block
          return if @warned_input_block

          @warned_input_block = true
          warn "[RubyReactor] DEPRECATION: the single-key `input :name do required(:name)... end` block is " \
               "deprecated. Use the inline form (`input :name, :string, min_size?: 2`) or the macro block " \
               "(`input :name do |i| ... end`) instead."
        end
        private :warn_deprecated_input_block

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

        # `resume: :background` — after `continue` validates and stores the
        # payload, the remaining work is enqueued to a worker instead of
        # running inline in the delivering process (webhook, admin UI).
        def interrupt(name, resume: :inline, &block)
          unless %i[inline background].include?(resume)
            raise RubyReactor::Error::ValidationError,
                  "interrupt :#{name} has invalid `resume: #{resume.inspect}` — " \
                  "use `:inline` (default, resume runs in the calling process) or " \
                  "`:background` (resume is enqueued to a worker)."
          end

          builder = RubyReactor::Dsl::InterruptBuilder.new(name, self, resume: resume)
          builder.instance_eval(&block) if block_given?

          step_config = builder.build
          steps[name] = step_config
          step_config
        end

        def returns(step_name = nil)
          if step_name
            reject_async_return_step!(step_name)
            @return_step = step_name
          end
          @return_step
        end

        def middleware(middleware_class, **options)
          middlewares << if options.empty?
                           middleware_class
                         else
                           [middleware_class, options]
                         end
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
            # Same shape as executor-built validation failures: expose the
            # structured field errors on the Failure itself.
            RubyReactor.Failure(error, validation_errors: errors, reactor_name: name)
          end
        end

        # Entry point for running the reactor
        def run(inputs = {})
          reactor = new
          result = reactor.run(inputs)
          attach_execution_id!(result, reactor.context.context_id)
        end

        def call(inputs = {})
          run(inputs)
        end

        def attach_execution_id!(result, execution_id)
          return result if result.respond_to?(:execution_id) && result.execution_id

          result.define_singleton_method(:execution_id) { execution_id }
          result
        end
        private :attach_execution_id!
      end
    end
  end
end
