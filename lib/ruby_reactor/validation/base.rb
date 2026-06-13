# frozen_string_literal: true

module RubyReactor
  module Validation
    class Base
      def self.call(data)
        new.call(data)
      end

      def call(data)
        raise NotImplementedError
      end

      protected

      def success(value)
        RubyReactor.Success(value)
      end

      def failure(errors)
        error = RubyReactor::Error::InputValidationError.new(errors)
        # Carry the structured field errors on the Failure itself so every
        # validation failure shape (reactor inputs via `run`, step args, step
        # output) exposes `validation_errors` uniformly.
        RubyReactor.Failure(error, validation_errors: errors)
      end
    end
  end
end
