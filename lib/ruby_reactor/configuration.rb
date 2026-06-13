# frozen_string_literal: true

require "singleton"

module RubyReactor
  # Configuration class for RubyReactor settings
  class Configuration
    include Singleton

    attr_writer :sidekiq_queue, :sidekiq_retry_count, :logger, :async_router,
                :lock_snooze_base_delay, :lock_snooze_jitter, :lock_snooze_max_attempts,
                :middlewares

    def sidekiq_queue
      @sidekiq_queue ||= :default
    end

    def sidekiq_retry_count
      @sidekiq_retry_count ||= 3
    end

    # Base seconds the Sidekiq worker waits before re-checking a contended lock.
    def lock_snooze_base_delay
      @lock_snooze_base_delay ||= 5
    end

    # Extra random seconds added to the base delay to avoid thundering herd.
    def lock_snooze_jitter
      @lock_snooze_jitter ||= 5
    end

    # How many times a single job can snooze on lock contention before it is
    # marked as failed. Set to :infinity to never escalate.
    def lock_snooze_max_attempts
      @lock_snooze_max_attempts ||= 20
    end

    def logger
      @logger ||= Logger.new($stderr)
    end

    def async_router
      @async_router ||= RubyReactor::SidekiqAdapter
    end

    def storage
      @storage ||= RubyReactor::Storage::Configuration.new
    end

    def storage_adapter
      @storage_adapter ||= case storage.adapter
                           when :redis
                             RubyReactor::Storage::RedisAdapter.new(url: storage.redis_url, **storage.redis_options)
                           else
                             raise "Unknown storage adapter: #{storage.adapter}"
                           end
    end

    def middlewares
      @middlewares ||= []
    end

    # Registry of named rate limits shared across reactors. Configure entries
    # with `config.rate_limits.register(:name, ...)` and reference them from a
    # reactor via `with_rate_limit(:name)`.
    def rate_limits
      @rate_limits ||= RubyReactor::RateLimitRegistry.new
    end
  end
end
