# frozen_string_literal: true

module RubyReactor
  module Dsl
    # The one `retries` vocabulary. A step class EXTENDS it (class-level DSL);
    # the step, compose and async_reactor builders INCLUDE it, so every form
    # shares the same defaults and validation. Modeled on
    # `Lockable::ClassMethods`: `inherited` copies the declaration down, so a
    # subclass redeclaring leaves its parent and siblings untouched.
    module Retryable
      BACKOFF_STRATEGIES = %i[exponential linear fixed].freeze

      # The declared policy, or nil when nothing was declared.
      attr_reader :retry_config

      def retries(max_attempts: 3, backoff: :exponential, base_delay: 1)
        unless max_attempts.is_a?(Integer) && max_attempts >= 1
          invalid_retries!(:max_attempts, "an Integer >= 1", max_attempts)
        end
        invalid_retries!(:backoff, "one of #{BACKOFF_STRATEGIES.inspect}", backoff) unless
          BACKOFF_STRATEGIES.include?(backoff)
        invalid_retries!(:base_delay, "a Numeric >= 0", base_delay) unless
          base_delay.is_a?(Numeric) && base_delay >= 0

        @retry_config = { max_attempts: max_attempts, backoff: backoff, base_delay: base_delay }
      end

      def inherited(subclass)
        super
        subclass.instance_variable_set(:@retry_config, @retry_config) if @retry_config
      end

      private

      def invalid_retries!(option, expected, value)
        raise ArgumentError, "#{retry_owner_label}: retries #{option} must be #{expected} (got #{value.inspect})"
      end

      # A step class's name, or a builder's step name.
      def retry_owner_label
        name&.to_s || inspect
      end
    end
  end
end
