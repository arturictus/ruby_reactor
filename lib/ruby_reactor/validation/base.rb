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
        RubyReactor.Failure(error)
      end
    end
  end
end