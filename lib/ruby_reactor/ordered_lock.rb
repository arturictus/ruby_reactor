# frozen_string_literal: true

module RubyReactor
  # Strict-ordering primitive. A monotonically increasing nonce is assigned at
  # enqueue time; the worker can proceed only when its nonce equals
  # `last_completed + 1`. Otherwise the worker raises {WaitError}, which the
  # Sidekiq worker rescues and re-snoozes via `perform_in`.
  #
  # See `with_ordered_lock` for usage from a reactor.
  class OrderedLock
    # Raised by the gate check when the worker's nonce is ahead of
    # `last_completed + 1`. Carries `retry_after_seconds`, a hint derived from
    # the poison-pill timeout on the *blocker* nonce.
    class WaitError < StandardError
      attr_reader :retry_after_seconds, :key, :nonce, :last_completed

      def initialize(key:, nonce:, last_completed:, retry_after_seconds:)
        @key = key
        @nonce = nonce
        @last_completed = last_completed
        @retry_after_seconds = retry_after_seconds
        super("OrderedLock '#{key}' nonce #{nonce} waiting on #{last_completed + 1}")
      end
    end

    # Default poison-pill: if the blocker nonce was assigned more than
    # `poison_pill_timeout` seconds ago and never advanced, the gate treats it
    # as dead and advances past it. Prevents permanent head-of-line blocking
    # from a crashed caller that INCRed but never enqueued.
    DEFAULT_POISON_PILL_TIMEOUT = 600

    # TTL on the Redis counter keys. Bumped on every assign so an active
    # sequence never expires; only fully-drained ones GC themselves.
    DEFAULT_TTL = 86_400

    attr_reader :key, :nonce, :epoch, :poison_pill_timeout, :strict

    def initialize(key, nonce: nil, epoch: nil, poison_pill_timeout: DEFAULT_POISON_PILL_TIMEOUT, # rubocop:disable Metrics/ParameterLists
                   ttl: DEFAULT_TTL, strict: true)
      @key = key
      @nonce = nonce
      @epoch = epoch
      @poison_pill_timeout = poison_pill_timeout
      @ttl = ttl
      @strict = strict
    end

    # Atomic INCR on the `next` counter. Caller-side; runs during
    # `Reactor.run` BEFORE `perform_async`. Returns `[nonce, epoch]` — the nonce
    # we own plus the generation it belongs to (used to fence stale stragglers).
    def self.assign(key, ttl: DEFAULT_TTL)
      adapter = RubyReactor.configuration.storage_adapter
      adapter.ordered_lock_assign(key, ttl: ttl)
    end

    # Gate check. Returns `:go`, `:skip_chain_failed`, `:stale_batch`, or raises
    # {WaitError}.
    # - `:go` — proceed to run steps.
    # - `:skip_chain_failed` — only in strict mode: an earlier nonce in this
    #   sequence terminated with a Failure, so this run is short-circuited
    #   with `Skipped(reason: :ordered_lock_chain_failed)` without executing.
    # - `:stale_batch` — this run's epoch no longer matches the key's current
    #   generation: its batch fully drained and the numbering was reused by a
    #   newer batch. The run is short-circuited with
    #   `Skipped(reason: :ordered_lock_stale_batch)` and must not participate.
    # - `:poison_advance` is collapsed to `:go` from the caller's perspective.
    def check!
      raise ArgumentError, "OrderedLock#check! requires a nonce" unless @nonce

      state, retry_after, last_completed, first_failed = adapter.ordered_lock_can_proceed(
        @key,
        nonce: @nonce,
        poison_pill_timeout: @poison_pill_timeout,
        epoch: @epoch.to_i
      )

      case state
      when "go", "poison_advance"
        chain_failed?(first_failed) ? :skip_chain_failed : :go
      when "stale"
        :stale_batch
      when "wait"
        raise WaitError.new(
          key: @key,
          nonce: @nonce,
          last_completed: last_completed,
          retry_after_seconds: retry_after
        )
      else
        raise "Unexpected OrderedLock state: #{state.inspect}"
      end
    end

    # Move `last_completed` forward. Idempotent: only the nonce equal to
    # `last_completed + 1` advances; others are no-ops (the poison-pill path
    # may have already skipped us).
    #
    # Call on terminal status only (success, permanent failure, escalated skip).
    # Retryable failures must NOT advance — the same nonce keeps owning until
    # the job either succeeds or exhausts its retry budget.
    #
    # `failed:` records this nonce as the chain-failure marker (only the FIRST
    # failure sticks). In strict mode the marker causes subsequent nonces to
    # short-circuit with Skipped.
    def advance!(failed: false)
      raise ArgumentError, "OrderedLock#advance! requires a nonce" unless @nonce

      adapter.ordered_lock_advance(@key, nonce: @nonce, failed: failed, epoch: @epoch.to_i, ttl: @ttl)
    end

    # Restamp this nonce's `assigned_at` to "now" while its steps execute, so a
    # successor does not poison-advance past a blocker that is merely slow (not
    # dead). Called on an interval by a background heartbeat thread for the
    # duration of step execution. No-op if the nonce's timer was already deleted
    # by a terminal advance, or if the batch has gone stale (epoch fence).
    def heartbeat!
      return unless @nonce

      adapter.ordered_lock_heartbeat(@key, nonce: @nonce, epoch: @epoch.to_i)
    end

    # Read-only inspection. `{ next:, last_completed:, in_flight: [...] }`.
    def self.peek(key)
      RubyReactor.configuration.storage_adapter.ordered_lock_peek(key)
    end

    # Manual ops escape hatch — force-advance past a stuck nonce.
    def self.skip!(key, nonce:)
      RubyReactor.configuration.storage_adapter.ordered_lock_skip(key, nonce: nonce)
    end

    # Nuke all counters for a key. Ops only; concurrent enqueues during reset
    # produce undefined ordering.
    def self.reset!(key)
      RubyReactor.configuration.storage_adapter.ordered_lock_reset(key)
    end

    private

    def chain_failed?(first_failed)
      @strict && first_failed.to_i.positive? && @nonce > first_failed.to_i
    end

    def adapter
      RubyReactor.configuration.storage_adapter
    end
  end
end
