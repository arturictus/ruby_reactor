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
        @inline_contract = nil
        @rule_sites = []
      end

      # Deprecation notices print once per declaration site for the process.
      def self.deprecation_sites
        @deprecation_sites ||= Set.new
      end

      def argument(name, source, type = nil, transform: nil, **predicates)
        @arguments[name] = {
          source: source,
          transform: transform,
          origin: :explicit
        }

        return unless type || predicates.any?

        @arg_validations << [name, type, false, predicates]
        @rule_sites << [name, caller_locations(1, 1).first]
      end

      # An inline step's input contract. Inside the block `input` declares, as
      # in a step class; outside it `input(:x)` stays the template reference.
      def inputs(&block)
        if @impl
          raise Error::ValidationError,
                "step :#{@name}: `inputs` is for inline steps; declare `input` inside #{@impl} instead."
        end

        @inline_contract ||= RubyReactor::Step::InputContract.new(owner: @name)
        @inline_contract.instance_eval(&block)
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
        @validate_args_site = caller_locations(1, 1).first
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

      # The per-step hand-off flag is gone. Only the FIRST flagged step
      # in a reactor ever took effect — every later one was silently ignored —
      # so this must fail at class-definition time rather than surprise someone
      # at run time. Kept as a stub purely to say what to use instead.
      def async(*)
        raise RubyReactor::Error::DeprecatedDslError.new(
          "`async` inside a `step` block has been removed: it was ambiguous (only the first " \
          "flagged step in a reactor ever took effect). Replacements:\n  " \
          "* `background after: :#{@name}` — hand every REMAINING step to a worker once " \
          ":#{@name} finishes in the calling process (declared on the reactor, not the step);\n  " \
          "* `background before: :#{@name}` — hand off starting WITH :#{@name};\n  " \
          "* `async_step :#{@name}` — dispatch just this step's work to its own job while the " \
          "reactor keeps running;\n  " \
          "* `async_reactor :name, ChildReactor` — dispatch a whole nested reactor independently.",
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

      # `async_dispatch` marks a step whose work is dispatched as an independent
      # unit rather than run inline — `:step` for `async_step`, `:reactor` for
      # `async_reactor`. Nil for an ordinary step.
      def build(async_dispatch: nil)
        check_contract_conflicts!
        warn_deprecated_rules

        step_config = {
          async_dispatch: async_dispatch,
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
          inline_contract: @inline_contract,
          retry_config: @retry_config.empty? ? (@reactor&.retry_defaults || {}) : @retry_config
        }

        RubyReactor::Dsl::StepConfig.new(step_config)
      end

      private

      # A step that owns its input contract takes wiring only from the
      # reactor: rules here would be a second, overlapping rule set.
      def check_contract_conflicts!
        contract = owned_contract
        return unless contract

        owner = @impl || "its `inputs do ... end` block"
        if (arg = @arg_validations.first&.first)
          raise Error::ValidationError,
                "#{reactor_label} step :#{@name} declares rules on argument :#{arg}, but #{owner} owns its input " \
                "contract. Move the rule into #{owner} (`input :#{arg}, ...`) and keep only the wiring here: " \
                "`argument :#{arg}, <source>`."
        end
        if @validate_args_input
          raise Error::ValidationError,
                "#{reactor_label} step :#{@name} declares `validate_args`, but #{owner} owns its input contract. " \
                "Move the rule into #{owner} (`validate_inputs ...`) and keep only the wiring here."
        end

        unknown = @arguments.keys.find { |name| !contract.declares?(name) }
        return unless unknown

        raise Error::ValidationError,
              "#{reactor_label} step :#{@name} wires argument :#{unknown}, which #{owner} does not declare. " \
              "Declared inputs: #{contract.declarations.keys.join(", ")}."
      end

      # Rules on `argument` / `validate_args` still work for a step without a
      # contract; they now belong on the step itself.
      def warn_deprecated_rules
        target = @impl || "an `inputs do ... end` block"
        @rule_sites.each do |arg, site|
          warn_deprecation(site, "step :#{@name} declares rules on `argument :#{arg}`. Declare them on the step " \
                                 "instead (`input :#{arg}, ...` in #{target}) and keep `argument :#{arg}, <source>` " \
                                 "for wiring.")
        end
        return unless @validate_args_site

        warn_deprecation(@validate_args_site, "step :#{@name} declares rules with `validate_args`. Declare them on " \
                                              "the step instead (`validate_inputs` in #{target}).")
      end

      def warn_deprecation(site, message)
        location = "#{site.path}:#{site.lineno}"
        return unless StepBuilder.deprecation_sites.add?(location)

        warn "[RubyReactor] DEPRECATION: #{location} #{reactor_label} #{message} " \
             "Removal no earlier than the next MAJOR."
      end

      def owned_contract
        @inline_contract || (@impl.input_contract if @impl.respond_to?(:declares_inputs?) && @impl.declares_inputs?)
      end

      def reactor_label
        @reactor&.name || @reactor.inspect
      end
    end

    class StepConfig
      attr_reader :name, :impl, :arguments, :run_block, :compensate_block, :undo_block, :conditions, :guards,
                  :dependencies, :args_validator, :output_validator, :retry_config, :async_dispatch,
                  :inline_contract

      def initialize(config)
        @async_dispatch = config[:async_dispatch]
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
        @inline_contract = config[:inline_contract]
        @retry_config = { max_attempts: 1 }.merge(config[:retry_config] || {})
      end

      # True for `async_step` / `async_reactor` — the step's work leaves this
      # process instead of running inline. `RSpec::TestSubject`'s `async: false`
      # clears the marker to run the whole reactor in one process.
      def async_dispatch?
        !@async_dispatch.nil?
      end

      def has_impl?
        !@impl.nil?
      end

      # The contract that governs this step's inputs, or nil when it has none.
      def input_contract
        @inline_contract || (@impl.input_contract if @impl.respond_to?(:declares_inputs?) && @impl.declares_inputs?)
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
