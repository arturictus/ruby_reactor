# frozen_string_literal: true

module RubyReactor
  module Step
    def self.included(base)
      base.extend(ClassMethods)
      base.singleton_class.prepend(InputEnforcement)
    end

    # Validates the declared contract before the step's own `run`, on every
    # path that calls it: the executor, the async worker, and a direct call.
    # A step that declares no inputs goes straight to `super`.
    module InputEnforcement
      def run(arguments, context)
        return super unless declares_inputs?

        validated = begin
          input_contract.enforce!(arguments)
        rescue Error::InputValidationError => e
          e.step_name = name
          raise
        end
        super(validated, context)
      end
    end

    module ClassMethods
      include RubyReactor::StepSignals

      # A subclass's own `def self.run` would sit in front of the wrapper
      # prepended onto its parent, so every subclass gets its own.
      def inherited(subclass)
        super
        subclass.singleton_class.prepend(InputEnforcement)
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

      # rubocop:disable Naming/MethodName
      def Success(value = nil)
        RubyReactor::Success(value)
      end

      def Failure(error = nil)
        RubyReactor::Failure(error)
      end

      def Halt(reason: nil, **kwargs)
        RubyReactor.Halt(reason: reason, **kwargs)
      end

      def Skipped(...)
        RubyReactor.Skipped(...)
      end
      # rubocop:enable Naming/MethodName

      def run(arguments, context)
        raise NotImplementedError, "#{self} must implement .run method"
      end

      def compensate(_reason, _arguments, _context)
        RubyReactor.Skipped() # Default: nothing defined, rollback continues
      end

      def undo(_result, _arguments, _context)
        RubyReactor.Skipped() # Default: nothing defined, rollback continues
      end

      private

      def own_input_contract
        @own_input_contract ||= InputContract.new(owner: self)
      end
    end
  end
end
