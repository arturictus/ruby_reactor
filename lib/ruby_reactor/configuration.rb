# frozen_string_literal: true

require "singleton"

module RubyReactor
  # Configuration class for RubyReactor settings
  class Configuration
    include Singleton

    attr_writer :queue_name, :job_retry_count, :logger, :async_router,
                :lock_snooze_base_delay, :lock_snooze_jitter, :lock_snooze_max_attempts,
                :middlewares, :context_ttl, :context_lock_ttl, :checkpoint_min_interval,
                :sweeper_enabled, :sweeper_interval, :sweeper_limit

    def queue_name
      @queue_name ||= :default
    end

    # Deprecated alias for `queue_name` — kept so existing Sidekiq-only configs
    # don't break.
    def sidekiq_queue
      queue_name
    end

    def sidekiq_queue=(value)
      self.queue_name = value
    end

    # Retention TTL (seconds) for a stored reactor context. Storage is
    # load-bearing for resume, so this must comfortably exceed the worst-case
    # snooze/retry window. Refreshed on every checkpoint write.
    def context_ttl
      @context_ttl ||= 86_400
    end

    # Minimum wall-clock seconds between two PER-STEP durable checkpoints within a
    # single worker run. The save-per-step checkpoint (`on_step_complete`) bounds
    # crash re-execution to one step, but re-serializes and re-writes the WHOLE
    # root blob after every Success — O(steps × context_size) writes for a long,
    # large reactor. This throttle coalesces the mid-run intermediate checkpoints:
    # a checkpoint is written only if at least this many seconds have elapsed since
    # the last one. The final terminal/handoff state is ALWAYS persisted (by the
    # run's ensure-save and the pre-enqueue checkpoint), so throttling only affects
    # mid-run granularity. Tradeoff: with interval > 0, a crash may re-run every
    # step completed inside the last interval — safe only when those steps are
    # idempotent or side-effect-free.
    #
    # Default 0 -> checkpoint after EVERY step (strongest guarantee, no coalescing).
    def checkpoint_min_interval
      @checkpoint_min_interval ||= 0
    end

    # Whether the recovery sweepers run. The host kicks the self-rescheduling
    # chain once (`RubyReactor.start_sweeper!`, e.g. from an initializer); each
    # tick re-checks this flag, so flipping it to false stops the chain at the
    # next tick. Default on: durability is inert without a running sweeper, so
    # recovery must work out of the box.
    def sweeper_enabled
      @sweeper_enabled = true if @sweeper_enabled.nil?
      @sweeper_enabled
    end

    # Seconds between sweeps. This is the upper bound on recovery latency for a
    # dead worker — lower it for faster recovery, raise it to cut scan load.
    def sweeper_interval
      @sweeper_interval ||= 30
    end

    # Max contexts/maps inspected per sweep (passed to each sweeper's run_once).
    def sweeper_limit
      @sweeper_limit ||= 1000
    end

    # TTL (seconds) for the per-context liveness lock (`async:<id>`). Short by
    # design — it is a liveness signal, not retention. A live worker auto-extends
    # it (every ttl/3 s, from a background thread); its absence is the sweeper's
    # "worker died" signal.
    #
    # SAFETY CONSTRAINT: this MUST exceed the longest a single step can run
    # WITHOUT letting the auto-extend thread make progress. Under MRI the
    # extender shares the GIL, so a step that holds the GIL continuously for
    # longer than this TTL (a long CPU-bound pure-Ruby loop, a C extension that
    # never releases the GIL, or a stop-the-world GC pause) lets the lock lapse.
    # A lapsed lock looks "dead" to the sweeper, which may re-enqueue a duplicate
    # that runs CONCURRENTLY with the still-live original — a double-run. I/O-bound
    # steps release the GIL and keep the lock fresh, so the default 60s suits
    # typical workloads; raise it if you run long synchronous CPU-bound steps.
    def context_lock_ttl
      @context_lock_ttl ||= 60
    end

    def job_retry_count
      @job_retry_count ||= 3
    end

    # Deprecated alias for `job_retry_count` — kept so existing Sidekiq-only
    # configs don't break.
    def sidekiq_retry_count
      job_retry_count
    end

    def sidekiq_retry_count=(value)
      self.job_retry_count = value
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
      @logger ||= Logger.new($stdout)
    end

    def async_router
      @async_router ||= RubyReactor::Adapters::Sidekiq::Router
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
