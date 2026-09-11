# frozen_string_literal: true

module RubyReactor
  # The single inheritable base every class-based step derives from:
  #
  #   class MyStep < RubyReactor::Step
  #     input :amount, :integer
  #     def run = Success(charged: inputs[:amount])
  #   end
  #
  # Lifecycle: a class-level call (`.run`/`.call`, `.undo`, `.compensate`)
  # enforces the declared input contract (raising `Error::InputValidationError`
  # before any instance exists), builds a FRESH instance from the given
  # arguments/context (never reused across actions — an ivar set in `run` is
  # gone by the time `undo` runs on a separate instance, so async execution
  # running `run` and `undo` in different processes behaves identically to
  # running both in one), invokes the matching instance method, and translates
  # any `StepSignals` throw (`success!`/`skip!`/`fail!`/`halt!`) into its
  # result wrapper. No `prepend`/`extend`/`define_method`/`method_missing` —
  # every step in the class reads top to bottom as ordinary method calls.
  class Step
    include RubyReactor::StepSignals

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

    def Failure(error = nil)
      RubyReactor.Failure(error)
    end

    def Halt(reason: nil, **kwargs)
      RubyReactor.Halt(reason: reason, **kwargs)
    end

    def Skipped(...)
      RubyReactor.Skipped(...)
    end
    # rubocop:enable Naming/MethodName

    class << self
      def run(arguments, context)
        validated = enforce_contract!(arguments)
        catch(StepSignals::TAG) { new(validated, context).run }
      end
      alias call run

      def undo(result, arguments, context)
        catch(StepSignals::TAG) { new(arguments, context, result: result).undo }
      end

      def compensate(reason, arguments, context)
        catch(StepSignals::TAG) { new(arguments, context, reason: reason).compensate }
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

      def own_input_contract
        @own_input_contract ||= Step::InputContract.new(owner: self)
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
