# frozen_string_literal: true

module RubyReactor
  module Dsl
    class StepBuilder
      include RubyReactor::Dsl::TemplateHelpers
      include RubyReactor::Dsl::ValidationHelpers

      attr_accessor :name, :impl, :arguments, :run_block, :compensate_block, :undo_block, :conditions, :guards,
                    :dependencies, :args_validator, :output_validator, :retry_config

      def initialize(name, impl = nil, reactor = nil)
        @name = name
        @impl = impl
        @reactor = reactor
        @arguments = {}
        @run_block = nil
        @compensate_block = nil
        @undo_block = nil
        @conditions = []
        @guards = []
        @dependencies = []
        @arg_validations = []
        @validate_args_input = nil
        @args_validator = nil
        @output_validator = nil
        @retry_config = {}
      end

      def argument(name, source, type = nil, transform: nil, **predicates)
        @arguments[name] = {
          source: source,
          transform: transform
        }

        return unless type || predicates.any?

        @arg_validations << [name, type, false, predicates]
      end

      def run(&block)
        @run_block = block
      end

      def compensate(&block)
        @compensate_block = block
      end

      def undo(&block)
        @undo_block = block
      end

      def where(&predicate)
        @conditions << predicate
      end

      def guard(&guard_fn)
        @guards << guard_fn
      end

      def wait_for(*step_names)
        @dependencies.concat(step_names)
      end

      # Cross-field rules over the whole resolved argument hash. Composes with
      # per-argument inline validations declared via `argument`; the block (or
      # pre-built schema) is applied last and wins on conflicts.
      def validate_args(schema_or_validator = nil, &block)
        @validate_args_input = block || schema_or_validator
      end

      # Scalar-aware output validation.
      #   validate_output :integer, gteq?: 0   # single value
      #   validate_output do ... end            # hash output
      #   validate_output SomeSchema            # pre-built schema
      def validate_output(type = nil, **predicates, &block)
        @output_validator =
          if block
            create_input_validator(block)
          elsif type.is_a?(Symbol) || type.is_a?(Module) || predicates.any?
            build_scalar_validator(type, predicates)
          elsif type
            create_input_validator(type)
          end
      end

      # FR-003: the per-step hand-off flag is gone. Only the FIRST flagged step
      # in a reactor ever took effect — every later one was silently ignored —
      # so this must fail at class-definition time rather than surprise someone
      # at run time. Kept as a stub purely to say what to use instead.
      def async(*)
        raise RubyReactor::Error::DeprecatedDslError.new(
          "`async` inside a `step` block has been removed: it was ambiguous (only the first " \
          "flagged step in a reactor ever took effect). Replacements:\n" \
          "  * `background after: :#{@name}` — hand every REMAINING step to a worker once " \
          ":#{@name} finishes in the calling process (declared on the reactor, not the step);\n" \
          "  * `background before: :#{@name}` — hand off starting WITH :#{@name};\n" \
          "  * `async_step :#{@name}` — dispatch just this step's work to its own job while the " \
          "reactor keeps running;\n" \
          "  * `async_reactor :name, ChildReactor` — dispatch a whole nested reactor independently.",
          step: @name
        )
      end

      def retries(max_attempts: 3, backoff: :exponential, base_delay: 1)
        @retry_config = {
          max_attempts: max_attempts,
          backoff: backoff,
          base_delay: base_delay
        }
      end

      def build
        step_config = {
          name: @name,
          impl: @impl,
          arguments: @arguments,
          run_block: @run_block,
          compensate_block: @compensate_block,
          undo_block: @undo_block,
          conditions: @conditions,
          guards: @guards,
          dependencies: @dependencies,
          args_validator: @args_validator || build_args_validator(@arg_validations, @validate_args_input),
          output_validator: @output_validator,
          retry_config: @retry_config.empty? ? (@reactor&.retry_defaults || {}) : @retry_config
        }

        RubyReactor::Dsl::StepConfig.new(step_config)
      end
    end

    class StepConfig
      attr_reader :name, :impl, :arguments, :run_block, :compensate_block, :undo_block, :conditions, :guards,
                  :dependencies, :args_validator, :output_validator, :retry_config

      def initialize(config)
        @name = config[:name]
        @impl = config[:impl]
        @arguments = config[:arguments] || {}
        @run_block = config[:run_block]
        @compensate_block = config[:compensate_block]
        @undo_block = config[:undo_block]
        @conditions = config[:conditions] || []
        @guards = config[:guards] || []
        @dependencies = config[:dependencies] || []
        @args_validator = config[:args_validator]
        @output_validator = config[:output_validator]
        @retry_config = { max_attempts: 1 }.merge(config[:retry_config] || {})
      end

      def has_impl?
        !@impl.nil?
      end

      def has_run_block?
        !@run_block.nil?
      end

      def retryable?
        (retry_config[:max_attempts] || 0) > 1
      end

      def should_run?(context)
        @conditions.all? { |condition| condition.call(context) } &&
          @guards.all? { |guard| guard.call(context) }
      end

      def interrupt?
        false
      end
    end
  end
end
