# frozen_string_literal: true

module RubyReactor
  class Executor
    class InputValidator
      def initialize(reactor_class, context)
        @reactor_class = reactor_class
        @context = context
      end

      def validate!
        check_required_inputs
        validate_input_schemas
      end

      private

      def check_required_inputs
        @reactor_class.inputs.each do |input_name, input_config|
          next if input_config[:optional] || @context.inputs.key?(input_name) || @context.inputs.key?(input_name.to_s)

          raise Error::ValidationError.new(
            "Required input '#{input_name}' is missing",
            context: @context
          )
        end
      end

      def validate_input_schemas
        return unless @reactor_class.respond_to?(:input_validations) && @reactor_class.input_validations.any?

        validation_result = @reactor_class.validate_inputs(@context.inputs)
        return unless validation_result.failure?

        raise validation_result.error
      end
    end
  end
end