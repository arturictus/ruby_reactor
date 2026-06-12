# frozen_string_literal: true

module RubyReactor
  # Global registry of named rate limits, configured once via
  # `RubyReactor.configure`. Lets multiple reactors share a single quota for an
  # external service (e.g. all Stripe-calling reactors throttle against one
  # `:stripe` bucket).
  #
  # @example
  #   RubyReactor.configure do |config|
  #     config.rate_limits.register(:stripe, limit: 3, period: :second)
  #     config.rate_limits.register(:twilio, limits: { second: 10, minute: 100 })
  #   end
  #
  #   class ChargeReactor < RubyReactor::Reactor
  #     with_rate_limit(:stripe)
  #   end
  class RateLimitRegistry
    # Raised when a reactor references a rate-limit name that was never
    # registered. This is a configuration error, so it propagates out of
    # `execute` rather than being swallowed into a step failure result.
    class UnknownLimitError < StandardError; end

    def initialize
      @limits = {}
    end

    # Register a named rate limit. Same window args as the inline DSL form:
    # a single window (`limit:` + `period:`) or layered windows (`limits:`).
    def register(name, limit: nil, period: nil, limits: nil)
      @limits[name.to_sym] = RubyReactor::RateLimit.normalize_specs(
        limit: limit, period: period, limits: limits
      )
      self
    end

    # Return the normalized spec array for a registered name, or raise if the
    # name was never registered (resolved lazily at execute time, so the error
    # surfaces with a clear message instead of a nil dereference).
    def fetch(name)
      @limits.fetch(name.to_sym) do
        raise UnknownLimitError, "Unknown rate limit #{name.inspect}. " \
                                 "Register it with config.rate_limits.register(#{name.inspect}, ...)."
      end
    end

    def registered?(name)
      @limits.key?(name.to_sym)
    end
  end
end
