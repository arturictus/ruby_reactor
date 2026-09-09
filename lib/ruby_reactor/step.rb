# frozen_string_literal: true

module RubyReactor
  module Step
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      include RubyReactor::StepSignals

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
    end
  end
end
