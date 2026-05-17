# frozen_string_literal: true

module RubyReactor
  # Distributed rate limiter (fixed-window counter, multi-window aware).
  #
  # A `RateLimit` is configured with one or more (period, limit) tuples.
  # `check_and_increment!` atomically verifies every window has headroom and,
  # if so, increments all of them. The check uses a single Lua script so
  # nothing slips through between read and write.
  #
  # When any window is over-limit the call raises `ExceededError` carrying a
  # `retry_after_seconds` hint (time until the tightest failing bucket rolls).
  # The Sidekiq worker uses this hint to schedule a precise snooze.
  class RateLimit
    class ExceededError < StandardError
      attr_reader :retry_after_seconds, :key_base, :limit, :period_seconds, :period_name

      def initialize(message, retry_after_seconds:, key_base:, limit:, period_seconds:, period_name:) # rubocop:disable Metrics/ParameterLists
        super(message)
        @retry_after_seconds = retry_after_seconds
        @key_base = key_base
        @limit = limit
        @period_seconds = period_seconds
        @period_name = period_name
      end
    end

    attr_reader :key_base, :limits

    # @param key_base [String] caller-provided key (e.g. "stripe:account_42")
    # @param limits [Array<Hash>] each hash needs :period_seconds, :limit,
    #   and :name (used in the Redis bucket key and the error message)
    def initialize(key_base, limits:)
      @key_base = key_base
      @limits = limits
    end

    def check_and_increment!
      now = Time.now.to_i
      keys = @limits.map { |spec| bucket_key(spec, now) }
      argv = [now]
      @limits.each do |spec|
        argv << spec[:period_seconds]
        argv << spec[:limit]
        argv << (spec[:period_seconds] * 2) # TTL: generous, auto-cleans stale buckets
      end

      allowed, retry_after, failed_index = adapter.rate_limit_check_and_increment(keys, argv)
      return true if allowed == 1

      failed = @limits[failed_index - 1]
      raise ExceededError.new(
        "Rate limit '#{@key_base}' exceeded (#{failed[:limit]}/#{failed[:name]}); " \
        "retry in #{retry_after}s",
        retry_after_seconds: retry_after,
        key_base: @key_base,
        limit: failed[:limit],
        period_seconds: failed[:period_seconds],
        period_name: failed[:name]
      )
    end

    private

    def bucket_key(spec, now)
      bucket_id = now / spec[:period_seconds]
      "rate:#{@key_base}:#{spec[:name]}:#{bucket_id}"
    end

    def adapter
      RubyReactor.configuration.storage_adapter
    end
  end
end
