# frozen_string_literal: true

module RubyReactor
  # The single inheritable base every class-based step derives from:
  #
  #   class MyStep < RubyReactor::Step
  #     input :amount, :integer
  #     def run = Success(charged: inputs[:amount])
  #   end
  #
  # Lifecycle of every class-level call (`.run`/`.call`, `.undo`, `.compensate`):
  #
  # 1. Resolve `inputs`: the given arguments with the contract's defaults
  #    applied. `run`, `undo`, and `compensate` all see the same values.
  # 2. `.run` ONLY: enforce the declared input contract, raising
  #    `Error::InputValidationError` before any instance exists.
  # 2b. `.run` ONLY: step-scoped coordination (`with_lock` etc, if declared)
  #    is acquired around the rest of `.run`, keyed on the just-validated
  #    inputs — after contract enforcement, so a step that will fail
  #    validation never takes a hold (research Finding 7 / Finding 8). A
  #    reactor never goes through here: it calls `.run_without_coordination`
  #    and coordinates the step itself (research D2).
  #    `.undo` and `.compensate` NEVER enforce the input contract: rollback
  #    must not fail on the very inputs that may have caused the failure.
  # 3. Build a FRESH instance, never reused across actions. An ivar set in
  #    `run` is gone by the time `undo` runs on its own instance, so async
  #    execution running `run` and `undo` in different processes behaves
  #    identically to running both in one.
  # 4. Invoke the matching instance method, translating any `StepSignals`
  #    throw (`success!`/`skip!`/`fail!`/`halt!`) into its result wrapper.
  #
  # No `prepend`/`define_method`/`method_missing` — every step in the class
  # reads top to bottom as ordinary method calls. The two `extend`s are
  # `Dsl::Lockable::ClassMethods` (the five coordination macros) and
  # `Dsl::Retryable` (`retries`), self-contained modules whose only hook is
  # an `inherited` that copies their declarations down (Finding 9).
  class Step
    include RubyReactor::StepSignals
    extend RubyReactor::Dsl::Lockable::ClassMethods
    extend RubyReactor::Dsl::Retryable

    attr_reader :inputs, :context, :result, :reason

    def initialize(inputs, context, result: nil, reason: nil)
      @inputs = inputs
      @context = context
      @result = result
      @reason = reason
    end

    def run
      raise NotImplementedError, "#{self.class} must implement #run"
    end

    def undo
      RubyReactor.Skipped()
    end

    def compensate
      RubyReactor.Skipped()
    end

    # rubocop:disable Naming/MethodName
    def Success(value = nil)
      RubyReactor.Success(value)
    end

    def Failure(...)
      RubyReactor.Failure(...)
    end

    def Halt(reason: nil, **kwargs)
      RubyReactor.Halt(reason: reason, **kwargs)
    end

    def Skipped(...)
      RubyReactor.Skipped(...)
    end
    # rubocop:enable Naming/MethodName

    class << self
      # A DIRECT invocation — application code, or another step's body. It is
      # its own unit of work: it takes this class's coordination itself and,
      # having no queue to park into, waits then fails (FR-016/FR-023).
      # `context` is optional: a stand-alone `ChargeStep.run(args)` is its own
      # execution, with no reactor context to inherit ownership from.
      def run(arguments, context = nil)
        validated = enforce_contract!(arguments)
        coordinate(validated, context) { run_without_coordination(validated, context) }
      end
      alias call run

      # The reactor's entry (`StepConfig#call_body`): the executor or
      # `StepWorker` has already taken this step's EFFECTIVE coordination —
      # the class's declarations and any inline ones, in one fixed order — so
      # taking the class's here again would split acquisition across two
      # layers. Still enforces the contract (idempotent: it only applies
      # defaults to already-valid arguments).
      def run_without_coordination(arguments, context)
        validated = enforce_contract!(arguments)
        catch(StepSignals::TAG) { new(validated, context).run }
      end

      # Same `inputs` as `.run` (defaults applied), but NEVER enforces the contract.
      def undo(result, arguments, context)
        catch(StepSignals::TAG) { new(with_defaults(arguments), context, result: result).undo }
      end

      # Same `inputs` as `.run` (defaults applied), but NEVER enforces the contract.
      def compensate(reason, arguments, context)
        catch(StepSignals::TAG) { new(with_defaults(arguments), context, reason: reason).compensate }
      end

      def input(...)
        own_input_contract.input(...)
        @input_contract = nil
      end

      def validate_inputs(...)
        own_input_contract.validate_inputs(...)
        @input_contract = nil
      end

      def input_contract
        @input_contract ||=
          if superclass.respond_to?(:declares_inputs?) && superclass.declares_inputs?
            superclass.input_contract.merge(own_input_contract)
          else
            own_input_contract
          end
      end

      def declared_inputs
        input_contract.declarations
      end

      def required_input_names
        input_contract.required_names
      end

      def declares_inputs?
        !input_contract.empty?
      end

      private

      # Step-scoped coordination for a DIRECT call (`direct: true`): never
      # parks, keeps no state on `context`, and so can never be mistaken for
      # the coordination of the reactor step whose body made the call.
      # After `enforce_contract!`, so a step that will fail validation never
      # takes a hold (Finding 8). A bare step pays one check. `context` may be
      # nil (a stand-alone `MyStep.run(args)`) — `StepCoordination#owner`
      # handles that case.
      def coordinate(validated, context, &block)
        return block.call if Executor::StepCoordination.none?(self)

        ctx = context if context.is_a?(RubyReactor::Context)
        Executor::StepCoordination.new(
          step_config: self, arguments: validated, context: ctx, reactor_class: ctx&.reactor_class,
          middlewares: ctx&.middlewares || Executor.middlewares_for(ctx&.reactor_class), direct: true
        ).around_run(&block)
      end

      def own_input_contract
        @own_input_contract ||= Step::InputContract.new(owner: self)
      end

      def with_defaults(arguments)
        input_contract.apply_defaults(arguments)
      end

      def enforce_contract!(arguments)
        return arguments unless declares_inputs?

        input_contract.enforce!(arguments)
      rescue Error::InputValidationError => e
        e.step_name = name
        raise
      end
    end
  end
end
