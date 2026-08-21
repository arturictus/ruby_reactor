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
        base.instance_variable_set(:@background_handoff, nil)
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
          if async && background_handoff
            raise RubyReactor::Error::ValidationError,
                  "`async true` cannot be combined with `background " \
                  "#{background_handoff[:mode]}: :#{background_handoff[:step]}` on #{name || "this reactor"}: " \
                  "the whole reactor already runs in a worker, so a hand-off point inside it is meaningless. " \
                  "Drop one of the two."
          end

          @async = async
        end

        def async?
          @async ||= false
        end

        # FR-001/FR-002: the single, unambiguous cut point between what runs in
        # the calling process and what is handed to a worker. Replaces the
        # per-step `async` flag, where only the first flagged step ever took
        # effect and the rest were silently ignored.
        #
        #   background after:  :second   # :second is the LAST step to run here
        #   background before: :third    # :third is the FIRST step in the worker
        #
        # The two forms name one cut point from opposite sides — identical in a
        # linear chain, different in a DAG, where each pins the step it names.
        # Triggering is keyed to REACHING the named step, not to where this
        # declaration sits in the class body.
        def background(after: nil, before: nil)
          point = validate_background_declaration!(after, before)

          @background_handoff = point
        end

        # The normalized `{ mode:, step: }` pair — one reader, never a one-sided
        # `background_after`, so no consumer can be accidentally implemented for
        # `after:` only.
        def background_handoff
          @background_handoff
        end

        def validate_background_declaration!(after, before)
          if after && before
            raise RubyReactor::Error::ValidationError,
                  "`background` takes exactly one of `after:` or `before:`, got both " \
                  "(after: :#{after}, before: :#{before}). They name the same cut point from opposite " \
                  "sides: `after: :x` keeps :x in the calling process, `before: :x` moves it to the worker."
          end

          unless after || before
            raise RubyReactor::Error::ValidationError,
                  "`background` requires either `after: :step_name` (that step is the last to run in the " \
                  "calling process) or `before: :step_name` (that step is the first to run in the worker)."
          end

          point = { mode: after ? :after : :before, step: (after || before).to_sym }

          # Re-declaring the SAME point is a no-op — a class body can be
          # evaluated twice (Rails reloading, a spec reopening a fixture class)
          # and that must not be an error. A DIFFERENT second point is the real
          # footgun `background` exists to remove.
          if background_handoff && background_handoff != point
            raise RubyReactor::Error::ValidationError,
                  "#{name || "This reactor"} already declares `background " \
                  "#{background_handoff[:mode]}: :#{background_handoff[:step]}` and cannot also declare " \
                  "`background #{point[:mode]}: :#{point[:step]}`. A reactor has exactly one hand-off " \
                  "point — a second would reintroduce the ambiguity `background` exists to remove."
          end

          step_name = point[:step]
          unless steps.key?(step_name)
            raise RubyReactor::Error::ValidationError,
                  "`background` names unknown step :#{step_name}. Known steps: " \
                  "#{steps.keys.map { |k| ":#{k}" }.join(", ")}. The step must be defined before the " \
                  "`background` declaration."
          end

          if async?
            raise RubyReactor::Error::ValidationError,
                  "`background` cannot be combined with whole-reactor `async true` on " \
                  "#{name || "this reactor"}: the reactor already runs entirely in a worker, so a hand-off " \
                  "point inside it would be silently meaningless. Drop one of the two."
          end

          point
        end
        private :validate_background_declaration!

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
