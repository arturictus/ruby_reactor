# frozen_string_literal: true

module RubyReactor
  module Error
    class StepFailureError < Base
      def retryable?
        true
      end
    end
  end
end
