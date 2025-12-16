# frozen_string_literal: true

module RubyReactor
  module Dsl
    class InterruptStepConfig < StepConfig
      attr_reader :correlation_id_block, :timeout_config, :validation_schema, :strategy

      def initialize(config)
        super
        @correlation_id_block = config[:correlation_id_block]
        @timeout_config = config[:timeout_config]
        @validation_schema = config[:validation_schema]
      end

      def interrupt?
        true
      end
    end
  end
end
