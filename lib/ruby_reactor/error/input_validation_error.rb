# frozen_string_literal: true

module RubyReactor
  module Error
    class InputValidationError < Base
      attr_reader :field_errors
      # Step attribution, set at the raise site when the failure happened at a
      # step boundary (argument or output validation) rather than at reactor
      # input validation. Nil for reactor-level input failures.
      attr_accessor :step_name, :step_arguments

      def initialize(field_errors)
        @field_errors = field_errors
        @message = build_message
        super(@message)
      end

      def build_message
        return "Input validation failed" if field_errors.empty?

        error_messages = field_errors.map do |field, errors|
          "#{field} #{errors}"
        end

        "Input validation failed: #{error_messages.join(", ")}"
      end

      def to_s
        @message || build_message
      end
    end
  end
end
