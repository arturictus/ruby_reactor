# frozen_string_literal: true

module RubyReactor
  class Executor
    # Acquire/release the coordination a STEP declares (`with_lock` etc.),
    # around that step's own work only — never the whole reactor. Built fresh
    # per step execution, and exactly ONE instance guards any one invocation
    # (research D2), in one of two modes:
    #
    #   - reactor-driven (the default): `StepExecutor` / `StepWorker` build it
    #     from the `StepConfig`, so it sees the step's EFFECTIVE declarations
    #     (inline and class alike, in one global order), its retry policy and
    #     its output validator. Inside a worker, contention raises `Contended`
    #     for the caller to park the execution on.
    #   - `direct: true`: `Step.run` called by application code or by another
    #     step's body. Its own unit of work (FR-023): it waits the configured
    #     `wait:` then fails, keeps no state on the context, and never parks.
    #
    # Order (contracts/dsl-surface.md §3): ordered-lock gate, period
    # fast-check, lock, semaphore, period re-check, rate limit, body, mark
    # period. The rate limit is the LAST acquisition because it is the only
    # one that cannot be handed back — nothing after it can contend, so a
    # spent slot is never followed by a park. A park therefore releases
    # everything this step took, exactly like reactor-level contention, and
    # carries nothing across the gap but its ordered-lock position (FR-015:
    # the contended step's work has not started, so there is nothing to
    # protect in between).
    # rubocop:disable Metrics/ClassLength
    class StepCoordination
      # The step's key proc raised, or returned nil/empty. The step fails
      # before its body runs; the cause and the step name are both surfaced.
      class KeyError < RubyReactor::Error::Base; end

      # An `async_step` refused at dispatch because it declares a key this
      # execution holds (`AsyncStepDispatch`). Nothing was dispatched or run.
      class DispatchRefused < RubyReactor::Error::Base; end

      # A semaphore slot has no hold expiry to bound a rollback wait by, so it
      # waits the lock's default `ttl` instead (005 D-F1). A constant, not a
      # config key — add one if someone needs it.
      DEFAULT_ROLLBACK_WAIT = 60

      # A `Contended`/`KeyError` raised by a DIRECT `Step.run` inside this
      # step's body. The body had already started, so for THIS step it is an
      # ordinary failure — compensated, never parked — and must not be
      # mistaken for a failure of this step's own acquisition.
      class NestedCoordinationError < StandardError; end

      # Raised when a primitive cannot be acquired. Carries enough to build
      # both the synchronous failure message and the worker's park decision.
      class Contended < StandardError
        attr_reader :primitive, :key, :step_name, :reactor_name, :original

        # `message:` overrides the default wording for a re-wrap that needs to
        # say something else (the contention-ceiling failure in
        # `StepExecutor#contention_ceiling_failure`, a rollback that could not
        # re-acquire) while staying a `Contended`.
        def initialize(primitive:, key:, step_name:, reactor_name:, original:, message: nil) # rubocop:disable Metrics/ParameterLists
          @primitive = primitive
          @key = key
          @step_name = step_name
          @reactor_name = reactor_name
          @original = original
          default = "#{reactor_name} step :#{step_name} could not acquire #{primitive} '#{key}': #{original.message}"
          super(message || default)
        end

        # RateLimit::ExceededError and OrderedLock::WaitError carry a precise
        # hint; Lock/Semaphore::AcquisitionError do not (nil falls back to the
        # configured base delay in Worker.snooze_delay).
        def retry_after_seconds
          original.retry_after_seconds if original.respond_to?(:retry_after_seconds)
        end
      end

      attr_reader :step_config, :arguments, :context, :reactor_class, :middlewares

      # rubocop:disable Metrics/ParameterLists
      def initialize(step_config:, arguments:, context:, reactor_class:, middlewares:, direct: false)
        # rubocop:enable Metrics/ParameterLists
        @step_config = step_config
        @arguments = arguments
        @context = context
        @reactor_class = reactor_class
        @middlewares = middlewares
        @direct = direct
      end

      # FR-007, in one place: a key proc that returns nil/empty or raises fails
      # the step before its work runs, naming the step and the cause. Shared
      # with `AsyncStepDispatch`'s deadlock guard, which computes the same key
      # outside an instance and must fail the same (non-retryable) way.
      def self.resolve_key(config, arguments, step_name)
        key = config[:key_proc].call(arguments)
        if key.nil? || key.to_s.empty?
          raise KeyError.new("#{step_name}: coordination key proc returned nil/empty", step: step_name)
        end

        key
      rescue KeyError
        raise
      rescue StandardError => e
        raise KeyError.new(
          "#{step_name}: coordination key proc raised #{e.class}: #{e.message}",
          step: step_name, original_error: e
        )
      end

      # THE forward enforcement site for a step a reactor runs — `StepExecutor`
      # in-process and `StepWorker` for an `async_step` both come through
      # here, so the two paths cannot drift. Arguments are validated first
      # (InputValidationError before any hold, Finding 8), then the step's
      # effective declarations are taken once around its body.
      def self.run_step(step_config, resolved_arguments, context:, reactor_class:, middlewares:)
        arguments = step_config.body_arguments(resolved_arguments, context.inputs)
        body = -> { call_body(step_config, arguments, context) }
        return body.call if none?(step_config)

        new(step_config: step_config, arguments: arguments, context: context, reactor_class: reactor_class,
            middlewares: middlewares).around_run(&body)
      end

      # A `Contended`/`KeyError` escaping a reactor step's body was raised by a
      # nested DIRECT `Step.run` in it — whether or not this step declares
      # anything itself — so it is re-raised as `NestedCoordinationError`.
      def self.call_body(step_config, arguments, context)
        step_config.call_body(arguments, context)
      rescue Contended, KeyError => e
        raise NestedCoordinationError, e.message
      end
      private_class_method :call_body

      # True when constructing a StepCoordination would be pointless — lets
      # every call site skip it with one check per step (plan: "a step
      # declaring nothing pays one nil check per step").
      def self.none?(step_config)
        !step_config.respond_to?(:declares_coordination?) || !step_config.declares_coordination?
      end

      # The one piece of step state a contention park carries across the gap
      # is its ordered-lock position — a park must not lose its place in line.
      # When the park is instead escalated to a TERMINAL failure (the
      # `lock_snooze_max_attempts` ceiling, in `StepExecutor#handle_contention`
      # and `StepWorker#handle_contention`) no redelivery will consume it, so
      # advance it here or every later position stalls for the full
      # `poison_pill_timeout`.
      def self.discard_parked_state!(context)
        return unless context.is_a?(RubyReactor::Context)

        stash = context.private_data.delete(:step_ordered_locks) ||
                context.private_data.delete("step_ordered_locks") || {}
        stash.each_value do |raw|
          next unless raw.is_a?(Hash) && (raw[:key] || raw["key"])

          # `failed: true`: the step this position belongs to ended in a
          # failure, so strict successors must be chain-skipped, not run.
          Executor::OrderedLockSupport.advance_with_retry(raw.transform_keys(&:to_sym), failed: true)
        rescue StandardError => e
          RubyReactor.configuration.logger.warn(
            "RubyReactor could not advance parked ordered-lock position #{raw.inspect}: #{e.message}"
          )
        end
        context.private_data.delete(:step_contention)
      end

      # See the class comment for the order. Each stage is a bare yield when
      # its primitive is not declared. Release is the natural reverse via
      # nested `ensure`s: semaphore before lock (FR-008), lock before the
      # ordered-lock gate advances.
      def around_run(&block)
        result = ordered_lock_gate do
          period_fast_check do
            with_lock do
              with_semaphore do
                period_recheck do
                  rate_limited { run_body(&block) }
                end
              end
            end
          end
        end
        # Reaching here, or raising anything but this step's own `Contended`,
        # means the step is terminal for every declaration shape.
        clear_contention_state
        result
      # Neither is terminal: the execution parks (or, synchronously, the
      # caller turns contention into a failure) and this step's contention
      # counter and marker must survive the park.
      rescue Contended, Error::ExecutionParked
        raise
      rescue StandardError
        clear_contention_state
        raise
      end

      # Re-take exclusion primitives ONLY (lock, then semaphore) for
      # compensate/undo — never rate limit, period, or the ordered lock
      # (contracts/dsl-surface.md §6): a forward-work quota must never
      # suppress cleanup, and rollback is not part of the order forward work
      # runs in. Waits the declaration's own `rollback_wait` (default: the
      # lock's `ttl`, or `DEFAULT_ROLLBACK_WAIT` for a semaphore), never the
      # forward `wait:` — a forward holder finishes or expires within `ttl`,
      # so the undo outlasts it instead of being dropped (005 D-F1). Rollback
      # never parks: the execution is already mid-failure, so in a worker the
      # wait blocks the thread. A key still busy after the wait comes back as
      # a `Failure(Contended)` for `CompensationManager` to report.
      def around_rollback(&block)
        rollback_with_lock do
          rollback_with_semaphore(&block)
        end
      end

      private

      # Everything is acquired: this step is no longer waiting on anything.
      def run_body
        clear_contention_marker
        yield
      end

      def rollback_with_lock
        config = step_config.lock_config
        return yield unless config

        wait = config[:rollback_wait] || config[:ttl]
        acquire_for_rollback(:lock, config, wait) do |key|
          lock = RubyReactor::Lock.new(key, owner: owner, ttl: config[:ttl], wait: wait,
                                            auto_extend: config.fetch(:auto_extend, true))
          begin
            lock.acquire
          rescue RubyReactor::Lock::AcquisitionError => e
            next [nil, e]
          end
          push_key(key)
          emit(:lock_acquired, key)
          begin
            [yield, nil]
          ensure
            release_lock(lock)
            pop_key(key)
            emit(:lock_released, key)
          end
        end
      end

      def rollback_with_semaphore
        config = step_config.semaphore_config
        return yield unless config

        limit = config[:limit]
        wait = config[:rollback_wait] || DEFAULT_ROLLBACK_WAIT
        acquire_for_rollback(:semaphore, config, wait) do |key|
          begin
            semaphore = poll_semaphore(key, limit, wait)
          rescue RubyReactor::Semaphore::AcquisitionError => e
            next [nil, e]
          end
          push_key(key) if limit == 1
          emit(:semaphore_acquired, key, limit)
          begin
            [yield, nil]
          ensure
            release_semaphore(semaphore, key, limit)
          end
        end
      end

      # Polls instead of `Semaphore#acquire`'s blocking pop: the storage
      # adapter shares ONE Redis connection per process, and a blocking pop
      # held for up to `rollback_wait` would stall every other thread's Redis
      # call — lock auto-extenders and ordered-lock heartbeats included.
      def poll_semaphore(key, limit, wait)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait.to_f
        loop do
          semaphore = RubyReactor::Semaphore.new(key, limit: limit, wait: 0)
          semaphore.acquire
          return semaphore
        rescue RubyReactor::Semaphore::AcquisitionError
          raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.1
        end
      end

      # Shared "compute the key, run the acquire block, turn a failure into
      # the rollback Failure shape" wrapper for the two rollback primitives.
      # The block returns `[result, acquisition_error]`; a KeyError computing
      # the key itself is reported the same way.
      def acquire_for_rollback(primitive, config, wait)
        key = key_for(config)
        result, error = yield(key)
        return result unless error

        rollback_failure(primitive, key, error, wait)
      rescue KeyError => e
        rollback_failure(primitive, nil, e, wait)
      end

      # A `Contended`, not a bare string, so `CompensationManager` can report
      # the key and primitive on `Failure#rollback_failures`.
      def rollback_failure(primitive, key, error, wait)
        RubyReactor::Failure(
          Contended.new(
            primitive: primitive, key: key, step_name: step_name, reactor_name: reactor_label, original: error,
            message: "could not re-acquire #{primitive} '#{key}' for rollback of :#{step_name} within #{wait}s: " \
                     "#{error.message}"
          ),
          retryable: false, step_name: step_name
        )
      end

      # Strict-ordering gate (contract §3 position 1, research D8): the
      # position is assigned when the execution FIRST REACHES this step (its
      # key reads step arguments, which do not exist until then) — so
      # executions are ordered by arrival at the step, not by enqueue. Takes
      # nothing else while waiting for a turn (D3 step 1): out of turn, this
      # raises `Contended` before any other primitive is even attempted.
      def ordered_lock_gate(&block)
        config = step_config.ordered_lock_config
        return yield unless config

        info = ordered_lock_arrival_info(config)
        # Nested on a key this thread is already ordered on: no nonce was
        # assigned, so run ungated (see `ordered_lock_arrival_info`).
        return yield unless info

        # The same exhaustive classifier the reactor level uses (R-06). A
        # step's gate always runs before its body, so the position has never
        # started: always `fresh`.
        case gate_ordered_lock(info)
        when :go, :drained
          with_active_ordered_key(info[:key]) { run_under_ordered_lock(info, &block) }
        when :skip_chain
          # Terminal (skipped, not failed) — advance it like the executor's
          # reactor-level short-circuit does, or every later skipped step
          # stays in flight and the sequence never drains.
          Executor::OrderedLockSupport.advance_with_retry(info, failed: false)
          delete_ordered_lock_stash
          RubyReactor.Skipped(nil, reason: :ordered_lock_chain_failed, step_name: step_name)
        when :stale
          # The position belongs to a drained generation whose numbering a
          # newer batch reuses (F7): the body must not run unordered. No
          # advance — the epoch fence makes it a no-op — just drop the stash.
          delete_ordered_lock_stash
          RubyReactor.Skipped(nil, reason: :ordered_lock_stale_batch, step_name: step_name)
        end
      end

      # A `WaitError` means "not this nonce's turn yet". A worker parks and
      # keeps the position (the redelivery re-adopts the same nonce).
      # Synchronously the execution is terminal, and the position never held
      # the turn, so it has no failed work for successors to be protected
      # from: hand it back with `failed: false` (005 D-F3), or it would stall
      # every successor until the poison pill — and, with `failed: true`,
      # chain-skip every strict successor forever.
      def gate_ordered_lock(info)
        Executor::OrderedLockSupport.gate(info, fresh: true)
      rescue RubyReactor::OrderedLock::WaitError => e
        unless parking?
          Executor::OrderedLockSupport.advance_with_retry(info, failed: false)
          delete_ordered_lock_stash
        end
        raise Contended.new(primitive: :ordered_lock, key: info[:key], step_name: step_name,
                            reactor_name: reactor_label, original: e)
      end

      # Same thread-local guard `Reactor#assign_ordered_lock_nonce!` and
      # `OrderedLockSupport#enter_ordered_lock_scope` keep for reactor-level
      # ordering: while this step holds a position on `key`, a nested
      # `Reactor.run` (or step) on the same key must see it and skip assigning
      # a second nonce, or the two wait on each other until the poison pill.
      def with_active_ordered_key(key)
        active = Executor::OrderedLockSupport.active_keys
        active << key
        yield
      ensure
        idx = active.rindex(key)
        active.delete_at(idx) if idx
      end

      # Charged LAST, immediately before the body (see the class comment), so
      # a slot is only ever spent on work that is about to run. The rescue
      # covers the charge only — a `RateLimit::ExceededError` raised by the
      # body itself is the body's failure, not this step's contention.
      def rate_limited
        config = step_config.rate_limit_config
        return yield unless config

        key_base, limits = rate_limit_key_and_limits(config)
        charge_rate_limit(key_base, limits)
        yield
      end

      def charge_rate_limit(key_base, limits)
        RubyReactor::RateLimit.new(key_base, limits: limits).check_and_increment!
      rescue RubyReactor::RateLimit::ExceededError => e
        raise Contended.new(primitive: :rate_limit, key: key_base, step_name: step_name,
                            reactor_name: reactor_label, original: e)
      end

      # Named config resolves lazily against the registry (config order does
      # not matter). An unregistered name is a configuration mistake, not
      # contention: like a key that cannot be computed (FR-007) it fails the
      # step before its work, as this step's own `KeyError` — which the
      # executor and `StepWorker` both turn into a non-retryable,
      # never-started failure.
      def rate_limit_key_and_limits(config)
        if config[:name]
          [config[:name].to_s, RubyReactor.configuration.rate_limits.fetch(config[:name])]
        else
          [key_for(config), config[:limits]]
        end
      rescue RubyReactor::RateLimitRegistry::UnknownLimitError => e
        raise KeyError.new("#{step_name}: #{e.message}", step: step_name, original_error: e)
      end

      # First arrival assigns a fresh nonce and stashes it (keyed by step name)
      # so a redelivery or in-process retry of the SAME step re-reads the SAME
      # nonce (T060 scenario 5) instead of cutting in line with a fresh one. A
      # `Context` round-trips its `private_data` through JSON, symbolizing
      # every hash key at every depth — the per-step key comes back as a
      # Symbol even though it was stored as a String, so lookups check both.
      def ordered_lock_arrival_info(config)
        stash = ordered_lock_stash
        cached = stash[stash_key] || stash[stash_key.to_sym]
        return cached if cached

        key = key_for(config)
        # Nested under an ordered scope on the SAME key in this thread (an
        # outer step, or an outer `Reactor.run`): a second nonce would never
        # come up — the outer waits for this one to finish, this one waits for
        # the outer to advance. Mirror `Reactor#assign_ordered_lock_nonce!`:
        # skip assignment, warn, and let the inner work run ungated.
        if Executor::OrderedLockSupport.active_keys.include?(key)
          RubyReactor.configuration.logger.warn(
            "RubyReactor: step :#{step_name} declares `with_ordered_lock` on key '#{key}', which this " \
            "thread is already ordered on — nonce assignment skipped, the step runs without ordering " \
            "enforcement. Use a different key, or move the nested call to a top-level invocation."
          )
          return nil
        end

        nonce, epoch = RubyReactor::OrderedLock.assign(key, ttl: config[:ttl])
        info = {
          key: key, nonce: nonce, epoch: epoch, poison_pill_timeout: config[:poison_pill_timeout],
          ttl: config[:ttl], strict: config.fetch(:strict, true)
        }
        stash[stash_key] = info
        info
      end

      # On the context only for a reactor-driven step — the one mode with a
      # redelivery or retry to carry the position to. A direct call's position
      # lives and dies with this instance, so it can never collide with the
      # stash of the reactor step whose body made the call.
      def ordered_lock_stash
        return @ordered_lock_stash ||= {} unless context_state?

        context.private_data[:step_ordered_locks] ||= {}
      end

      def delete_ordered_lock_stash
        stash = context_state? ? context.private_data[:step_ordered_locks] : @ordered_lock_stash
        return unless stash

        stash.delete(stash_key)
        stash.delete(stash_key.to_sym)
      end

      def stash_key
        step_name.to_s
      end

      # Heartbeats while the body runs so a merely-slow step is not
      # poison-passed by a successor (T061). The position's fate is decided
      # ONCE, as `outcome`, and carried out in `ensure` — so every exit,
      # including one that is not a `StandardError`, stops the heartbeat
      # (005 R-07, F8). This position passed the gate, so it held the turn: a
      # failure here is the chain's failure (`failed: true`, D-F3).
      def run_under_ordered_lock(info)
        heartbeat = Executor::OrderedLockSupport.start_heartbeat(info)
        outcome = :abandoned
        begin
          result = yield
          outcome = if retry_pending?(result)
                      :retry_pending
                    elsif chain_failed?(result)
                      :failed
                    else
                      :succeeded
                    end
          result
        rescue Contended
          # Lock/semaphore/rate-limit contention after the gate: parked in a
          # worker it keeps its place; synchronously it is terminal.
          outcome = parking? ? :parked : :failed
          raise
        rescue Error::ExecutionParked
          outcome = :parked
          raise
        rescue StandardError
          outcome = :failed
          raise
        ensure
          heartbeat.stop
          finish_position(info, outcome)
        end
      end

      # - :succeeded / :failed — terminal: advance (a failure records the
      #   strict chain marker) and drop the stash.
      # - :retry_pending / :parked — `RetryManager` or the redelivery runs this
      #   step again and must keep its place: the stash survives, so the next
      #   attempt re-reads the SAME nonce. The heartbeat is stopped across the
      #   gap; `poison_pill_timeout` bounds it.
      # - :abandoned — an exit that is not a `StandardError` (`Sidekiq::Shutdown`,
      #   `NoMemoryError`, ...). Not advanced: `Sidekiq::Shutdown` pushes the
      #   job back to run again, which must keep this place, and `failed: true`
      #   would poison successors for work that may yet complete. With the
      #   heartbeat stopped, the poison pill releases the position within
      #   `poison_pill_timeout`.
      def finish_position(info, outcome)
        return unless %i[succeeded failed].include?(outcome)

        Executor::OrderedLockSupport.advance_with_retry(info, failed: outcome == :failed)
        delete_ordered_lock_stash
      end

      # Mirrors `RetryManager#handle_failure_result`'s decision, made here one
      # moment earlier: `prepare_retry_attempt` has already counted this
      # attempt, so both read the same numbers and agree. A direct call has no
      # retry policy of its own — it is never retried.
      def retry_pending?(result)
        return false unless context_state?
        return false unless result.is_a?(RubyReactor::Failure) && result.retryable?

        max_attempts = step_config.retry_config[:max_attempts]
        return false unless max_attempts.to_i > 1

        context.retry_context.can_retry_step?(step_name, max_attempts)
      end

      # The reactor validates a step's output AFTER `around_run` returns, so a
      # body that succeeded with a contract-violating value would advance this
      # position (or mark the period bucket) as successful even though the
      # step is about to be turned into a failure. `step_config` is the
      # reactor's `StepConfig` for every reactor-driven step, class-backed or
      # inline, so its validator is always visible here; re-run it (it is a
      # pure check).
      def chain_failed?(result)
        return true if result.is_a?(RubyReactor::Failure)
        return false unless result.is_a?(RubyReactor::Success)

        validator = step_config.respond_to?(:output_validator) && step_config.output_validator
        return false unless validator

        !validator.call(result.value).success?
      rescue StandardError
        false
      end

      def with_lock
        config = step_config.lock_config
        return yield unless config

        key = key_for(config)
        lock = RubyReactor::Lock.new(
          key, owner: owner, ttl: config[:ttl], wait: wait_for(config[:wait]),
               auto_extend: config.fetch(:auto_extend, true)
        )
        begin
          lock.acquire
        rescue RubyReactor::Lock::AcquisitionError => e
          emit(:lock_failed, key, e)
          raise Contended.new(primitive: :lock, key: key, step_name: step_name, reactor_name: reactor_label,
                              original: e)
        end
        push_key(key)
        emit(:lock_acquired, key)

        begin
          yield
        ensure
          release_lock(lock)
          pop_key(key)
          emit(:lock_released, key)
        end
      end

      def with_semaphore
        config = step_config.semaphore_config
        return yield unless config

        key = key_for(config)
        limit = config[:limit]
        semaphore = RubyReactor::Semaphore.new(key, limit: limit, wait: wait_for(config[:wait]))
        begin
          semaphore.acquire
        rescue RubyReactor::Semaphore::AcquisitionError => e
          emit(:semaphore_failed, key, limit, e)
          raise Contended.new(primitive: :semaphore, key: key, step_name: step_name, reactor_name: reactor_label,
                              original: e)
        end
        # Only a single-slot semaphore has the circular-wait shape the async
        # deadlock guard can act on (T032/T034) — mirrors `Executor#acquire_semaphore`.
        push_key(key) if limit == 1
        emit(:semaphore_acquired, key, limit)

        begin
          yield
        ensure
          release_semaphore(semaphore, key, limit)
        end
      end

      # Dedup window, fast pre-check (contract §3 position 2): mirrors
      # `Executor#check_period_gate` — skips a step already marked without
      # spending a lock/semaphore attempt on it. NOT authoritative by itself:
      # two callers can both pass this check before either marks the bucket,
      # so `period_recheck` repeats it UNDER the exclusion primitives, which
      # is what actually closes the race.
      def period_fast_check
        config = step_config.period_config
        return yield unless config
        return skipped_for_period if storage_adapter.period_seen?(period_key(config))

        yield
      end

      # Dedup window, re-check (contract §3 position 5): the authoritative
      # check, taken under lock/semaphore and before the rate limit, so two
      # racing callers serialize here, only the first marks the bucket, and a
      # deduplicated step never spends a rate-limit slot.
      #
      # Marked only on a plain `Success` whose output the reactor will accept
      # — never `Skipped`/`Halt` (no work happened), a failure, or a value the
      # output contract is about to reject (`chain_failed?`), any of which
      # would dedup away the next legitimate run.
      def period_recheck
        config = step_config.period_config
        return yield unless config

        key = period_key(config)
        return skipped_for_period if storage_adapter.period_seen?(key)

        result = yield
        if plain_success?(result) && !chain_failed?(result)
          storage_adapter.period_mark(key, RubyReactor::Period.ttl_seconds(config[:every]))
        end
        result
      end

      def skipped_for_period
        RubyReactor.Skipped(nil, reason: :period, step_name: step_name)
      end

      def plain_success?(result)
        result.is_a?(RubyReactor::Success) && !result.is_a?(RubyReactor::Halt) && !result.is_a?(RubyReactor::Skipped)
      end

      def period_key(config)
        RubyReactor::Period.key(key_for(config), config[:every])
      end

      def storage_adapter
        RubyReactor.configuration.storage_adapter
      end

      # Only a reactor-driven step running in a worker has a redelivery to
      # park into; a direct call or a synchronous run is terminal.
      def parking?
        context_state? && context.inline_async_execution
      end

      # Whether this invocation's state (ordered-lock position, contention
      # counter and marker) belongs on the context. Never for a direct call:
      # its context is the CALLER's execution, whose step state it must not
      # read or overwrite.
      def context_state?
        !@direct && context.is_a?(RubyReactor::Context)
      end

      # Mirrors `Executor#contention_wait`: inside a worker, fail fast instead
      # of blocking the thread — the caller snoozes via `perform_in` instead.
      def wait_for(configured)
        parking? ? 0 : configured
      end

      def clear_contention_marker
        context.private_data.delete(:step_contention) if context_state?
      end

      # Deliberately only on a terminal result, never per acquisition: a step
      # declaring several primitives acquires them one at a time, so resetting
      # the counter earlier would restart the `lock_snooze_max_attempts`
      # budget on every redelivery that gets past the first primitive.
      def clear_contention_state
        return unless context_state?

        clear_contention_marker
        context.retry_context.clear_contention_for_step(step_name)
      end

      # Never raises: a release failure must not mask the step's own result
      # (mirrors `Executor#release_one`).
      def release_lock(lock)
        released = lock.release
        return if released

        RubyReactor.configuration.logger.warn(
          "RubyReactor lock '#{lock.key}' was not held at release time (likely TTL expired or owner changed)"
        )
      rescue StandardError => e
        RubyReactor.configuration.logger.warn("RubyReactor failed to release lock '#{lock.key}': #{e.message}")
      end

      def release_semaphore(semaphore, key, limit)
        semaphore.release
        pop_key(key) if limit == 1
        emit(:semaphore_released, key)
      rescue StandardError => e
        RubyReactor.configuration.logger.warn("RubyReactor failed to release semaphore '#{key}': #{e.message}")
      end

      # The coordination hooks are shared with reactor-level coordination;
      # mark these as this step's for the duration of the call, so a
      # middleware can attribute them without guessing from `current_step`.
      def emit(event, *args)
        return middlewares.on(event, *args, context) unless context.is_a?(RubyReactor::Context)

        previous = context.coordinating_step
        context.coordinating_step = step_name
        begin
          middlewares.on(event, *args, context)
        ensure
          context.coordinating_step = previous
        end
      end

      def reactor_label
        reactor_class&.name || reactor_class.inspect
      end

      # re-entrancy: same owner as every reactor in this execution tree
      # (research D5, full rule landed in US4/T037).
      def owner
        @owner ||= context&.coordination_owner ||
                   ((context.root_context || context).context_id if context) ||
                   SecureRandom.uuid
      end

      def key_for(config)
        StepCoordination.resolve_key(config, arguments, step_name)
      end

      # A direct call is its own unit of work: it names the step class that
      # was invoked, never the caller's `current_step` — that is the step
      # whose body made the call (F9).
      def step_name
        return step_config.name if @direct || !context.is_a?(RubyReactor::Context)

        context.current_step || step_config.name.to_s
      end

      def push_key(key)
        held_lock_keys << key
      end

      # Pop ONE occurrence, not every occurrence (Finding 1) — a nested hold
      # on the same key (reactor + step, or step + inner step) must leave the
      # outer hold's entry intact for the async deadlock guard to keep seeing
      # the key while the outer scope is still open.
      def pop_key(key)
        keys = held_lock_keys
        idx = keys.index(key)
        keys.delete_at(idx) if idx
      end

      def held_lock_keys
        root = context && (context.root_context || context)
        return [] unless root

        root.private_data[:held_lock_keys] ||= []
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
