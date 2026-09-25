# frozen_string_literal: true

module RubyReactor
  module Dsl
    module Lockable
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        attr_reader :lock_config, :semaphore_config, :period_config, :rate_limit_config, :ordered_lock_config

        # The five configs, nils compacted. Reactors get this too (additive);
        # steps use it to decide whether `StepCoordination` needs building at
        # all (`StepCoordination.none?`).
        def coordination_declarations
          {
            lock: lock_config,
            semaphore: semaphore_config,
            rate_limit: rate_limit_config,
            period: period_config,
            ordered_lock: ordered_lock_config
          }.compact
        end

        def declares_coordination?
          !coordination_declarations.empty?
        end

        # Propagate lock/semaphore/period/rate-limit config to subclasses;
        # without this a subclass of a configured reactor would silently lose
        # those settings.
        def inherited(subclass)
          super
          subclass.instance_variable_set(:@lock_config, @lock_config) if @lock_config
          subclass.instance_variable_set(:@semaphore_config, @semaphore_config) if @semaphore_config
          subclass.instance_variable_set(:@period_config, @period_config) if @period_config
          subclass.instance_variable_set(:@rate_limit_config, @rate_limit_config) if @rate_limit_config
          subclass.instance_variable_set(:@ordered_lock_config, @ordered_lock_config) if @ordered_lock_config
        end

        # Configure locking for this reactor or step
        # @param ttl [Integer] Time to live in seconds (default: 60)
        # @param wait [Integer] Time to wait for lock in seconds (default: 0)
        # @param auto_extend [Boolean] When true (default), a background thread
        #   refreshes the lock TTL every ttl/3 seconds while the reactor runs,
        #   protecting steps that may legitimately outlast `ttl`. Pass `false`
        #   to disable and rely solely on `ttl` for expiry.
        # @param rollback_wait [Numeric, nil] STEP only (accepted and ignored on
        #   a reactor, whose holds are not re-taken for rollback): how long the
        #   step's `undo`/`compensate` waits to re-take this lock. Defaults to
        #   `ttl` — a forward holder either finishes or expires within it.
        #   Rollback never parks: in a worker the wait blocks the thread. An
        #   undo that cannot re-take the key in time is reported on
        #   `Failure#rollback_failures`.
        # @yield [inputs] Block that returns the lock key string. On a reactor,
        #   `inputs` is the reactor's inputs; on a step, it is the step's own
        #   resolved arguments (contract defaults applied).
        def with_lock(ttl: 60, wait: 0, auto_extend: true, rollback_wait: nil, &block)
          validate_rollback_wait!(rollback_wait)
          @lock_config = {
            ttl: ttl,
            wait: wait,
            auto_extend: auto_extend,
            rollback_wait: rollback_wait,
            key_proc: block
          }
        end

        # Configure semaphore for this reactor or step
        # @param limit [Integer] Maximum concurrent executions
        # @param wait [Integer] Time to wait for a token in seconds (default: 0)
        # @param rollback_wait [Numeric, nil] STEP only, as for `with_lock`.
        #   Defaults to 60 seconds: a semaphore slot has no hold expiry.
        # @yield [inputs] Block that returns the semaphore key string. On a
        #   reactor, `inputs` is the reactor's inputs; on a step, it is the
        #   step's own resolved arguments.
        def with_semaphore(limit:, wait: 0, rollback_wait: nil, &block)
          validate_rollback_wait!(rollback_wait)
          @semaphore_config = {
            limit: limit,
            wait: wait,
            rollback_wait: rollback_wait,
            key_proc: block
          }
        end

        def validate_rollback_wait!(value)
          return if value.nil? || (value.is_a?(Numeric) && value >= 0)

          raise ArgumentError, "rollback_wait must be a number of seconds >= 0 (got #{value.inspect})"
        end
        private :validate_rollback_wait!

        # Configure a calendar-aligned dedup window for this reactor or step.
        # On a reactor, a hit returns `RubyReactor::Halt` without executing
        # any steps. On a STEP, a hit instead skips just that step
        # (`RubyReactor.Skipped(reason: :period)`) — halting the whole
        # workflow over one deduplicated step would defeat the point of
        # declaring it at step level; the rest of the workflow runs normally.
        #
        # Note: `with_period` is *dedup*, not *concurrency*. Two concurrent
        # racers can both see no marker and both run. Pair with `with_lock`
        # for true at-most-one semantics within the bucket.
        #
        # @param every [Symbol, Integer] :minute / :hour / :day / :week /
        #   :month / :year, or an integer number of seconds for a sliding
        #   bucket (index = `time.to_i / every`).
        # @yield [inputs] Block that returns the period key base. The final
        #   Redis marker key is `period:<base>:<bucket_id>`. On a reactor,
        #   `inputs` is the reactor's inputs; on a step, it is the step's own
        #   resolved arguments.
        def with_period(every:, &block)
          # Validate eagerly so misconfiguration surfaces at class load time.
          RubyReactor::Period.period_seconds(every)

          @period_config = {
            every: every,
            key_proc: block
          }
        end

        # Configure strict-ordering nonce gating for this reactor or step. On
        # a reactor, a monotonically increasing nonce is assigned at enqueue
        # time; the worker can only proceed when its nonce equals
        # `last_completed + 1`. Otherwise the worker raises
        # {OrderedLock::WaitError} and the Sidekiq worker snoozes via
        # `perform_in`. On a step, the nonce is assigned on first arrival
        # instead — see the `@yield` note below.
        #
        # Counters reset to 0 once the sequence fully drains (last_completed
        # catches up to next). Re-entrancy is NOT supported — a nested reactor
        # with its own `with_ordered_lock` is an independent sequence.
        #
        # @param poison_pill_timeout [Integer] seconds since the blocker nonce
        #   was assigned before the gate auto-advances past it. Protects
        #   against permanent head-of-line blocking from a caller that INCRed
        #   the counter but crashed before enqueueing.
        # @param ttl [Integer] TTL on the counter keys, refreshed on every
        #   assign. Only fully-drained sequences GC themselves.
        # @param strict [Boolean] When true (default), if any nonce in the
        #   sequence terminates with a `Failure`, all subsequent nonces are
        #   short-circuited with `Halt(reason: :ordered_lock_chain_failed)`
        #   instead of executing. This models "stop the line on the first
        #   problem" pipelines (e.g. ledger transactions). When false, the
        #   sequence keeps executing every nonce in order regardless of prior
        #   failures. The poison state is per-key and clears on full drain. The
        #   check only applies to a fresh `execute`; an already-started run
        #   that paused (InterruptResult/DispatchResult) completes on resume even
        #   if the chain failed in the meantime.
        # @yield [inputs] Block that returns the ordered-lock key string. On a
        #   STEP, the position is assigned when the execution first REACHES
        #   the step (its key reads step arguments, which do not exist until
        #   then), so executions are ordered by ARRIVAL at that step, not by
        #   enqueue — identical to the reactor form only when the step is
        #   first in its reactor. The deeper the step, the weaker the
        #   promise (research D8, contract §1).
        def with_ordered_lock(poison_pill_timeout: OrderedLock::DEFAULT_POISON_PILL_TIMEOUT,
                              ttl: OrderedLock::DEFAULT_TTL,
                              strict: true,
                              &block)
          @ordered_lock_config = {
            poison_pill_timeout: poison_pill_timeout,
            ttl: ttl,
            strict: strict,
            key_proc: block
          }
        end

        # Configure rate limiting for this reactor or step (fixed-window
        # counter). Pass either a single window via `limit:` + `period:`, or
        # a hash of windows via `limits:` for layered API quotas.
        #
        # @example Single window
        #   with_rate_limit(limit: 3, period: :second) { |i| "stripe:#{i[:account_id]}" }
        #
        # @example Multi-window (3/sec AND 100/min AND 5000/hr)
        #   with_rate_limit(
        #     limits: { second: 3, minute: 100, hour: 5000 }
        #   ) { |i| "stripe:#{i[:account_id]}" }
        #
        # @example Named global limit (registered in `RubyReactor.configure`)
        #   with_rate_limit(:stripe)
        #
        # @param name [Symbol] reference a rate limit registered via
        #   `config.rate_limits.register`. When given, the limit is shared
        #   across every reactor using that name (the name is the key base);
        #   no `limit:`/`period:`/`limits:` or block is accepted.
        # @param limit [Integer] requests per period (single-window form)
        # @param period [Symbol, Integer] :second / :minute / :hour / :day /
        #   :week / :month / :year, or integer seconds (single-window form)
        # @param limits [Hash{Symbol,Integer => Integer}] mapping of period
        #   unit to limit (multi-window form)
        # @yield [inputs] Block returning the rate-limit key base (inline
        #   forms). On a reactor, `inputs` is the reactor's inputs; on a
        #   step, it is the step's own resolved arguments.
        def with_rate_limit(name = nil, limit: nil, period: nil, limits: nil, &block)
          if name
            if limit || period || limits || block
              raise ArgumentError, "with_rate_limit(:#{name}) references a registered limit; " \
                                   "do not also pass :limit/:period/:limits or a block"
            end

            @rate_limit_config = { name: name.to_sym }
            return
          end

          @rate_limit_config = {
            limits: RubyReactor::RateLimit.normalize_specs(limit: limit, period: period, limits: limits),
            key_proc: block
          }
        end
      end
    end
  end
end
