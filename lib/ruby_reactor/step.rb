# frozen_string_literal: true

module RubyReactor
  module Step
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def run(arguments, context)
        raise NotImplementedError, "#{self} must implement .run method"
      end

      def compensate(_reason, _arguments, _context)
        RubyReactor.Success() # Default: accept failure and continue rollback
      end

      def undo(_result, _arguments, _context)
        RubyReactor.Success() # Default: no-op undo
      end
    end
  end
end
