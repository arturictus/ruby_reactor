# frozen_string_literal: true

module RubyReactor
  module Dsl
    class InterruptStepConfig < StepConfig
      attr_reader :correlation_id_block, :timeout_config, :validation_schema, :strategy, :max_attempts,
                  :resume_mode

      def initialize(config)
        super
        @correlation_id_block = config[:correlation_id_block]
        @timeout_config = config[:timeout_config]
        @validation_schema = config[:validation_schema]
        @max_attempts = config[:max_attempts] || 1
        @resume_mode = config[:resume_mode] || :inline
      end

      def interrupt?
        true
      end

      def background_resume?
        @resume_mode == :background
      end
    end
  end
end
