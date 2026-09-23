# frozen_string_literal: true

module RubyReactor
  class Executor
    # Acquire/release the coordination a STEP declares (`with_lock` etc.),
    # around that step's own work only — never the whole reactor. Built fresh
    # per step execution (no ivar on `StepExecutor`, so nothing survives past
    # the step it was built for — see US2's scope guarantee).
    #
    # Enforcement lives in two call sites, never both for the same step
    # (research D2 / Finding 8):
    #   - Class steps: `Step.run`, after `enforce_contract!`, around the
    #     instance's `run` (T013).
    #   - Inline steps: `StepExecutor#run_step_implementation`'s
    #     `has_run_block?` branch, around the `run_block` call (T013).
    #
    # Order of acquisition follows contracts/dsl-surface.md §3: ordered-lock
    # gate, period fast-check, rate limit, lock, semaphore, period re-check —
    # implemented incrementally (US1 first takes just the lock; US5 restructures
    # `around_run` into the full fixed order).
    # rubocop:disable Metrics/ClassLength
    class StepCoordination
      # The step's key proc raised, or returned nil/empty. The step fails
      # before its body runs; the cause and the step name are both surfaced.
      class KeyError < RubyReactor::Error::Base; end

      # Raised when a primitive cannot be acquired. Carries enough to build
      # both the synchronous failure message and the worker's park decision.
      class Contended < StandardError
        attr_reader :primitive, :key, :step_name, :reactor_name, :original

        # `message:` overrides the default wording for a re-wrap that needs to
        # say something else (the contention-ceiling failure in
        # `RetryManager#park_for_contention`) while staying a `Contended`.
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

      # Coordination scopes currently open on THIS thread, innermost last —
      # what `#marker_name` reads to tell a nested direct class-step
      # invocation apart from the reactor step it runs inside.
      SCOPE_KEY = :ruby_reactor_step_coordination_scopes

      attr_reader :step_config, :arguments, :context, :reactor_class, :middlewares

      # rubocop:disable Metrics/ParameterLists
      def initialize(step_config:, arguments:, context:, reactor_class:, middlewares:, owner: nil, park: true)
        # rubocop:enable Metrics/ParameterLists
        @step_config = step_config
        @arguments = arguments
        @context = context
        @reactor_class = reactor_class
        @middlewares = middlewares
        @explicit_owner = owner
        @park = park
      end

      # True when constructing a StepCoordination would be pointless — lets
      # every call site skip it with one nil check per step (plan: "a step
      # declaring nothing pays one nil check per step").
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

      def self.none?(step_config)
        !step_config.respond_to?(:declares_coordination?) || !step_config.declares_coordination?
      end

      # A contention park deliberately KEEPS this step's holds: the lock stays
      # checked out (detached), the semaphore token stays out of the pool, the
      # rate-limit charge is remembered and the ordered-lock position is left
      # un-advanced, all so the redelivery re-adopts them (FR-018). When that
      # park is instead escalated to a TERMINAL failure — the
      # `lock_snooze_max_attempts` ceiling, in `RetryManager#park_for_contention`
      # and `StepWorker#handle_contention` — no redelivery is coming, so nothing
      # would ever give them back: the key would stay locked and the slot
      # unavailable until their TTLs expire, and every later ordered position
      # would stall for the full `poison_pill_timeout`. Hand them all back here.
      def self.discard_parked_state!(context)
        return unless context.is_a?(RubyReactor::Context)

        release_parked_locks(context)
        release_parked_semaphores(context)
        advance_parked_ordered_locks(context)
        context.private_data.delete(:step_rate_limits)
        context.private_data.delete(:step_contention)
      end

      def self.release_parked_locks(context)
        each_parked(context, :step_parked_locks) do |info|
          key = info[:key]
          next unless key

          RubyReactor::Lock.new(key, owner: info[:owner], auto_extend: false).release
        end
      end

      def self.release_parked_semaphores(context)
        each_parked(context, :step_parked_semaphores) do |info|
          key = info[:key]
          token = info[:token]
          next unless key && token

          semaphore = RubyReactor::Semaphore.new(key, limit: info[:limit] || 1)
          semaphore.release if semaphore.reattach(token)
        end
      end

      def self.advance_parked_ordered_locks(context)
        each_parked(context, :step_ordered_locks) do |info|
          next unless info[:key]

          # `failed: true`: the step this position belongs to ended in a
          # failure, so strict successors must be chain-skipped, not run.
          Executor::OrderedLockSupport.advance_with_retry(info, failed: true)
        end
      end

      # One-shot read of a per-step stash, normalising the JSON round-trip
      # (string keys on the way back in) and never letting one bad entry stop
      # the rest — this runs on an already-failing path.
      def self.each_parked(context, stash_name)
        stash = context.private_data.delete(stash_name) ||
                context.private_data.delete(stash_name.to_s) || {}

        stash.each_value do |raw|
          next unless raw.is_a?(Hash)

          yield raw.transform_keys(&:to_sym)
        rescue StandardError => e
          RubyReactor.configuration.logger.warn(
            "RubyReactor could not discard parked #{stash_name} entry #{raw.inspect}: #{e.message}"
          )
        end
      end
      private_class_method :release_parked_locks, :release_parked_semaphores,
                           :advance_parked_ordered_locks, :each_parked

      # order: see contracts/dsl-surface.md §3 — ordered-lock gate, period
      # fast-check, rate limit, lock, semaphore, period re-check, yield, mark
      # period on a plain Success. Each stage is a no-op (a bare yield) when
      # its primitive is not declared, so an undeclared primitive costs one
      # `nil` check. Release is the natural reverse via nested nested
      # `ensure`s: semaphore releases before lock (FR-008), lock before the
      # ordered-lock gate (Phase 11) advances.
      def around_run(&block)
        enter_scope
        result = ordered_lock_gate do
          period_fast_check do
            rate_limited do
              with_lock do
                with_semaphore do
                  run_with_period_recheck(&block)
                end
              end
            end
          end
        end
        # Terminal: contention raises, so reaching here means the step is done
        # (success, failure or skip). Clear the parked markers for EVERY
        # declaration shape — a rate-limit-only or ordered-lock-only step never
        # passes through the lock/semaphore clears below, and a stale marker
        # makes the API report a finished step as still waiting.
        clear_contention_state
        result
      ensure
        leave_scope
      end

      # Re-take exclusion primitives ONLY (lock, then semaphore) for
      # compensate/undo — never rate limit, period, or the ordered lock
      # (contracts/dsl-surface.md §6): a forward-work quota must never
      # suppress cleanup. Uses the CONFIGURED `wait` directly, not
      # `wait_for` — rollback never parks, the execution is already
      # mid-failure and there is nowhere to park it to.
      #
      # The ordered lock in particular (Phase 11, data-model rollback table)
      # is never re-taken here: its guarantee is about the ORDER forward
      # work runs in, which rollback is not part of — re-acquiring it would
      # make a cleanup wait on unrelated forward-work positions for no
      # benefit.
      def around_rollback(&block)
        rollback_with_lock do
          rollback_with_semaphore(&block)
        end
      end

      private

      def rollback_with_lock
        config = step_config.lock_config
        return yield unless config

        acquire_for_rollback(:lock, config) do |key|
          lock = RubyReactor::Lock.new(key, owner: owner, ttl: config[:ttl], wait: config[:wait],
                                            auto_extend: config.fetch(:auto_extend, true))
          begin
            lock.acquire
          rescue RubyReactor::Lock::AcquisitionError => e
            next [nil, e]
          end
          push_key(key)
          middlewares.on(:lock_acquired, key, context)
          begin
            [yield, nil]
          ensure
            release_lock(lock)
            pop_key(key)
            middlewares.on(:lock_released, key, context)
          end
        end
      end

      def rollback_with_semaphore
        config = step_config.semaphore_config
        return yield unless config

        limit = config[:limit]
        acquire_for_rollback(:semaphore, config) do |key|
          semaphore = RubyReactor::Semaphore.new(key, limit: limit, wait: config[:wait])
          begin
            semaphore.acquire
          rescue RubyReactor::Semaphore::AcquisitionError => e
            next [nil, e]
          end
          push_key(key) if limit == 1
          middlewares.on(:semaphore_acquired, key, limit, context)
          begin
            [yield, nil]
          ensure
            release_semaphore(semaphore, key, limit)
          end
        end
      end

      # Shared "compute the key, run the acquire block, turn a failure into
      # the rollback Failure shape" wrapper for the two rollback primitives.
      # The block returns `[result, acquisition_error]`; a KeyError computing
      # the key itself is reported the same way.
      def acquire_for_rollback(primitive, config)
        key = key_for(config)
        result, error = yield(key)
        return result unless error

        rollback_failure(primitive, key, error)
      rescue KeyError => e
        rollback_failure(primitive, nil, e)
      end

      def rollback_failure(primitive, key, error)
        RubyReactor::Failure(
          "could not re-acquire #{primitive} '#{key}' for rollback of :#{step_name}: #{error.message}",
          retryable: false, step_name: step_name
        )
      end

      # Strict-ordering gate (contract §3 position 1, research D8): the
      # position is assigned when the execution FIRST REACHES this step (its
      # key reads step arguments, which do not exist until then) — so
      # executions are ordered by arrival at the step, not by enqueue. Takes
      # nothing else while waiting for a turn (D3 step 1): out of turn, this
      # raises `Contended` before rate limit / lock / semaphore are even
      # attempted.
      def ordered_lock_gate(&block)
        config = step_config.ordered_lock_config
        return yield unless config

        info = ordered_lock_arrival_info(config)
        # Nested on a key this thread is already ordered on: no nonce was
        # assigned, so run ungated (see `ordered_lock_arrival_info`).
        return yield unless info

        gate = gate_ordered_lock(info)

        if gate == :skip_chain_failed
          # This position is terminal (skipped, not failed) — advance it like
          # the executor's reactor-level short-circuit does, or every later
          # skipped step stays in flight and the sequence never drains.
          Executor::OrderedLockSupport.advance_with_retry(info, failed: false)
          delete_ordered_lock_stash
          return RubyReactor.Skipped(nil, reason: :ordered_lock_chain_failed, step_name: step_name)
        end

        with_active_ordered_key(info[:key]) { run_under_ordered_lock(info, &block) }
      end

      # The gate check itself. A `Contended` here means "not this nonce's turn
      # yet"; for a SYNCHRONOUS caller `StepExecutor#handle_contention` turns
      # that into a terminal failure with no redelivery to consume the stash,
      # so the position has to be handed back right here or every successor on
      # the key stalls until the poison_pill_timeout. Only a real async park
      # keeps it (a redelivery re-adopts the same nonce).
      def gate_ordered_lock(info)
        check_ordered_lock!(info)
      rescue Contended
        unless parking?
          Executor::OrderedLockSupport.advance_with_retry(info, failed: true)
          delete_ordered_lock_stash
        end
        raise
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

      def rate_limited
        config = step_config.rate_limit_config
        return yield unless config

        key_base, limits = rate_limit_key_and_limits(config)
        charge_rate_limit(key_base, limits) unless consume_rate_limit_marker

        parked = false
        begin
          yield
        rescue Contended
          parked = parking?
          raise
        ensure
          # FR-018 applied to the quota: a DEEPER primitive (lock, semaphore,
          # or a nested step) parked this execution after the slot was already
          # spent. Remember the charge so the redelivery re-adopts it instead
          # of spending a second slot — otherwise a `limit: 2` can be exhausted
          # by one execution parking twice, which contradicts the documented
          # no-double-charge behaviour.
          step_rate_limits[marker_name] = true if parked
        end
      end

      def charge_rate_limit(key_base, limits)
        RubyReactor::RateLimit.new(key_base, limits: limits).check_and_increment!
      rescue RubyReactor::RateLimit::ExceededError => e
        raise Contended.new(primitive: :rate_limit, key: key_base, step_name: step_name,
                            reactor_name: reactor_label, original: e)
      end

      def step_rate_limits
        return @step_rate_limits_local ||= {} unless context.is_a?(RubyReactor::Context)

        context.private_data[:step_rate_limits] ||= {}
      end

      # One-shot, same reasoning as `consume_parked_lock_marker`: a crash after
      # this read degrades to charging the quota again, never to a step running
      # uncharged forever.
      def consume_rate_limit_marker # rubocop:disable Naming/PredicateMethod
        stash = step_rate_limits
        !!(stash.delete(marker_name) || stash.delete(marker_name.to_sym))
      end

      # Named config resolves lazily against the registry (config order does
      # not matter); a `RateLimitRegistry::UnknownLimitError` here is a
      # configuration mistake, not contention — it propagates as an ordinary
      # exception (a normal non-retryable Failure once the executor's rescue
      # chain sees it), never wrapped as `Contended`.
      def rate_limit_key_and_limits(config)
        if config[:name]
          [config[:name].to_s, RubyReactor.configuration.rate_limits.fetch(config[:name])]
        else
          [key_for(config), config[:limits]]
        end
      end

      # First arrival assigns a fresh nonce and stashes it on the (root, for a
      # reactor-scoped stash would be wrong here — this is deliberately on
      # THIS context, not `root_context`, since ordering is per-step, not
      # per-execution) context, keyed by step name so a redelivery of the
      # SAME step re-reads the SAME nonce (T060 scenario 5) instead of
      # cutting in line with a fresh one. A `Context` round-trips its
      # `private_data` through JSON, symbolizing every hash key at every
      # depth — the dynamic per-step key comes back as a Symbol even though
      # it was stored as a String, so lookups check both.
      def ordered_lock_arrival_info(config)
        stash = ordered_lock_stash
        cached = stash[marker_name] || stash[marker_name.to_sym]
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
        stash[marker_name] = info
        info
      end

      def ordered_lock_stash
        return @ordered_lock_local_stash ||= {} unless context.is_a?(RubyReactor::Context)

        context.private_data[:step_ordered_locks] ||= {}
      end

      def delete_ordered_lock_stash
        stash = context.is_a?(RubyReactor::Context) ? context.private_data[:step_ordered_locks] : nil
        stash ||= @ordered_lock_local_stash
        return unless stash

        stash.delete(marker_name)
        stash.delete(marker_name.to_sym)
      end

      def check_ordered_lock!(info)
        RubyReactor::OrderedLock.new(
          info[:key], nonce: info[:nonce], epoch: info[:epoch],
                      poison_pill_timeout: info[:poison_pill_timeout], strict: info[:strict]
        ).check!
      rescue RubyReactor::OrderedLock::WaitError => e
        raise Contended.new(primitive: :ordered_lock, key: info[:key], step_name: step_name,
                            reactor_name: reactor_label, original: e)
      end

      # Heartbeats while the body runs so a merely-slow step is not
      # poison-passed by a successor (T061), then advances the cursor ONLY
      # on a terminal result. Only a `Contended` raised from deeper in
      # `around_run` (rate limit, lock, semaphore) leaves this position
      # un-advanced and its stash intact, so a redelivery resumes the SAME
      # nonce instead of losing its place in line; any other exception is
      # terminal and poisons the position.
      def run_under_ordered_lock(info)
        heartbeat = Executor::OrderedLockSupport.start_heartbeat(info)
        begin
          result = yield
        rescue Contended
          heartbeat.stop
          # Only a PARKED contention gets a redelivery to re-adopt this
          # position with. A synchronous one is terminal — `StepExecutor
          # #handle_contention`'s else branch turns it straight into a
          # Failure — so leaving the nonce in flight would stall every
          # successor on this key for the full poison_pill_timeout with
          # nothing ever coming back to advance it.
          unless parking?
            Executor::OrderedLockSupport.advance_with_retry(info, failed: true)
            delete_ordered_lock_stash
          end
          raise
        rescue StandardError
          # Anything else is terminal — `StepExecutor` turns it into a
          # `Failure`, so the position must be poisoned here or every
          # successor waits out the poison_pill_timeout for a nonce that is
          # never coming back.
          heartbeat.stop
          Executor::OrderedLockSupport.advance_with_retry(info, failed: true)
          delete_ordered_lock_stash
          raise
        end
        heartbeat.stop
        # A retryable failure with attempts left is NOT terminal: `RetryManager`
        # is about to run this step again (in-process, or as a redelivery), and
        # that attempt must keep this place in line. Advancing here would let
        # successors past and hand the retry a fresh nonce at the back of the
        # queue. The stash survives instead, so the next attempt re-reads the
        # SAME nonce. (The heartbeat is stopped across that gap, exactly as it
        # is across a contention park — `poison_pill_timeout` bounds both.)
        unless retry_pending?(result)
          Executor::OrderedLockSupport.advance_with_retry(info, failed: chain_failed?(result))
          delete_ordered_lock_stash
        end
        result
      end

      # Mirrors `RetryManager#handle_failure_result`'s decision, made here one
      # moment earlier: `prepare_retry_attempt` has already counted this
      # attempt, so both read the same numbers and agree.
      def retry_pending?(result)
        return false unless result.is_a?(RubyReactor::Failure) && result.retryable?
        return false unless context.is_a?(RubyReactor::Context)

        max_attempts = retry_policy&.[](:max_attempts)
        return false unless max_attempts.to_i > 1

        context.retry_context.can_retry_step?(step_name, max_attempts)
      end

      # `retries` is declared reactor-side, so for a CLASS step — where
      # `step_config` is the Step class itself (`Step.run` passes `self`) — the
      # policy has to be read off the reactor's own step definition.
      def retry_policy
        return step_config.retry_config if step_config.respond_to?(:retry_config)
        return nil unless context.is_a?(RubyReactor::Context)

        steps = context.reactor_class&.steps
        steps && steps[step_name.to_sym]&.retry_config
      end

      # The reactor validates a step's output AFTER `around_run` returns, so a
      # body that succeeded with a contract-violating value would advance this
      # position as successful and let strict successors run even though the
      # step is about to be turned into a failure. Re-run the validator here
      # (it is a pure check) and poison the chain instead.
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

        acquire_or_reattach_lock(lock, key)

        parked = false
        begin
          yield
        rescue Contended
          parked = parking?
          raise
        ensure
          if parked
            # FR-018: a deeper primitive (the semaphore) parked this execution.
            # Keep this hold checked out across the gap — bounded by the TTL,
            # since `detach` stops the auto-extender — and re-adopt it on the
            # redelivery instead of releasing it and re-competing, which would
            # emit a second acquisition and leave a window for someone else.
            lock.detach
            step_parked_locks[marker_name] = { key: key, owner: owner }
            pop_key(key)
          else
            release_lock(lock)
            pop_key(key)
            middlewares.on(:lock_released, key, context)
          end
        end
      end

      # Re-adopting a hold kept across a contention park records no second
      # `:lock_acquired`; a lapsed hold (TTL expired mid-park) falls back to
      # competing normally.
      def acquire_or_reattach_lock(lock, key)
        reattached = consume_parked_lock_marker && lock.reattach

        unless reattached
          begin
            lock.acquire
          rescue RubyReactor::Lock::AcquisitionError => e
            middlewares.on(:lock_failed, key, e, context)
            raise Contended.new(primitive: :lock, key: key, step_name: step_name, reactor_name: reactor_label,
                                original: e)
          end
        end

        push_key(key)
        middlewares.on(:lock_acquired, key, context) unless reattached
        clear_contention_marker
      end

      # Only a worker-side execution has a redelivery to re-adopt a hold on;
      # a synchronous contention is terminal, so its lock must be released.
      def parking?
        @park && context.is_a?(RubyReactor::Context) && context.inline_async_execution
      end

      def step_parked_locks
        return @step_parked_locks_local ||= {} unless context.is_a?(RubyReactor::Context)

        context.private_data[:step_parked_locks] ||= {}
      end

      # One-shot (same reasoning as `Executor#consume_parked_primitives!`): a
      # crash after this read degrades to a fresh acquire, not a stale
      # reattach on some later, unrelated resume. The per-step key survives
      # the context's JSON round-trip as a Symbol, so both spellings are read.
      def consume_parked_lock_marker # rubocop:disable Naming/PredicateMethod
        stash = step_parked_locks
        !!(stash.delete(marker_name) || stash.delete(marker_name.to_sym))
      end

      def with_semaphore
        config = step_config.semaphore_config
        return yield unless config

        key = key_for(config)
        limit = config[:limit]
        semaphore = RubyReactor::Semaphore.new(key, limit: limit, wait: wait_for(config[:wait]))

        acquire_or_reattach_semaphore(semaphore, key, limit)

        parked = false
        begin
          yield
        rescue Contended
          parked = parking?
          raise
        ensure
          if parked
            # FR-018, same reasoning as `with_lock` above: a `Contended` from
            # deeper in (a nested or direct step) parked this execution. Keep
            # the slot checked out across the gap and re-adopt it on the
            # redelivery, rather than handing it back and letting another
            # execution into a step this one still holds.
            step_parked_semaphores[marker_name] = { key: key, token: semaphore.token, limit: limit }
            pop_key(key) if limit == 1
          else
            release_semaphore(semaphore, key, limit)
          end
        end
      end

      # Mirrors `acquire_or_reattach_lock`: a slot re-adopted across a park
      # records no second `:semaphore_acquired`; a token lost in between (pool
      # reset / expiry) falls back to competing normally.
      def acquire_or_reattach_semaphore(semaphore, key, limit)
        reattached = semaphore.reattach(consume_parked_semaphore_token)

        unless reattached
          begin
            semaphore.acquire
          rescue RubyReactor::Semaphore::AcquisitionError => e
            middlewares.on(:semaphore_failed, key, limit, e, context)
            raise Contended.new(primitive: :semaphore, key: key, step_name: step_name, reactor_name: reactor_label,
                                original: e)
          end
        end

        # Only a single-slot semaphore has the circular-wait shape the async
        # deadlock guard can act on (T032/T034) — mirrors `Executor#acquire_semaphore`.
        push_key(key) if limit == 1
        middlewares.on(:semaphore_acquired, key, limit, context) unless reattached
        clear_contention_marker
      end

      def step_parked_semaphores
        return @step_parked_semaphores_local ||= {} unless context.is_a?(RubyReactor::Context)

        context.private_data[:step_parked_semaphores] ||= {}
      end

      # One-shot, same reasoning as `consume_parked_lock_marker`; the per-step
      # key survives the context's JSON round-trip as a Symbol.
      def consume_parked_semaphore_token
        stash = step_parked_semaphores
        info = stash.delete(marker_name) || stash.delete(marker_name.to_sym)
        # The marker also carries the key and limit, so a park escalated to a
        # terminal failure can hand the slot back (`discard_parked_state!`).
        info.is_a?(Hash) ? (info[:token] || info["token"]) : info
      end

      # Dedup window, fast pre-check (contract §3 position 2): mirrors
      # `Executor#check_period_gate` — skips a step already marked without
      # spending a rate-limit slot or a lock/semaphore attempt on it. NOT
      # authoritative by itself: two callers can both pass this check before
      # either marks the bucket, so `run_with_period_recheck` repeats it
      # UNDER every other hold, which is what actually closes the race.
      def period_fast_check
        config = step_config.period_config
        return yield unless config

        if storage_adapter.period_seen?(period_key(config))
          return RubyReactor.Skipped(nil, reason: :period, step_name: step_name)
        end

        yield
      end

      # Dedup window, re-check (contract §3 position 6): the authoritative
      # check, taken after lock/semaphore so two racing callers serialize
      # here and only the first marks the bucket — the second sees it
      # already marked and is skipped instead of re-running the work.
      def run_with_period_recheck(&block)
        config = step_config.period_config
        return yield_and_mark(config, &block) unless config

        key = period_key(config)
        return RubyReactor.Skipped(nil, reason: :period, step_name: step_name) if storage_adapter.period_seen?(key)

        yield_and_mark(config, &block)
      end

      def yield_and_mark(config, &block)
        result = block.call
        # Output validation runs AFTER `around_run` returns (same reason
        # `chain_failed?` re-runs it): marking the bucket for a value the
        # contract is about to reject would dedup away the next invocation of a
        # step that in fact failed and was rolled back.
        mark_period_on_success(config, result) if config && plain_success?(result) && !chain_failed?(result)
        result
      end

      # Marked only on a plain `Success` — never `Skipped` (already deduped,
      # marking again is a no-op at best) and never `Halt` (a Halt short-
      # circuited the step's own work; marking a bucket for work that did not
      # happen would suppress a legitimate retry later).
      def plain_success?(result)
        result.is_a?(RubyReactor::Success) && !result.is_a?(RubyReactor::Halt) && !result.is_a?(RubyReactor::Skipped)
      end

      def mark_period_on_success(config, _result)
        storage_adapter.period_mark(period_key(config), RubyReactor::Period.ttl_seconds(config[:every]))
      end

      def period_key(config)
        RubyReactor::Period.key(key_for(config), config[:every])
      end

      def storage_adapter
        RubyReactor.configuration.storage_adapter
      end

      # Once any primitive is successfully acquired, the step is no longer
      # waiting on THAT one — drop the parked-state marker T025 set on the
      # previous (failed) attempt, so an operator reading `private_data` never
      # sees a stale "waiting on" for a step that is now running.
      #
      # Deliberately NOT the contention counter: a step declaring several
      # primitives acquires them one at a time, so resetting the counter here
      # would restart the budget on every redelivery that gets past the first
      # primitive — a step parked forever on its semaphore while re-adopting
      # its lock would never reach `lock_snooze_max_attempts` at all. The
      # counter is cleared only when the step reaches a terminal result.
      def clear_contention_marker
        return unless context.is_a?(RubyReactor::Context)

        context.private_data.delete(:step_contention)
      end

      def clear_contention_state
        return unless context.is_a?(RubyReactor::Context)

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
        middlewares.on(:semaphore_released, key, context)
      rescue StandardError => e
        RubyReactor.configuration.logger.warn("RubyReactor failed to release semaphore '#{key}': #{e.message}")
      end

      def reactor_label
        reactor_class&.name || reactor_class.inspect
      end

      # re-entrancy: same owner as every reactor in this execution tree
      # (research D5, full rule landed in US4/T037).
      def owner
        @owner ||= @explicit_owner ||
                   context&.coordination_owner ||
                   ((context.root_context || context).context_id if context) ||
                   SecureRandom.uuid
      end

      # Mirrors `Executor#contention_wait`: inside a worker, fail fast instead
      # of blocking the thread — the caller snoozes via `perform_in` instead.
      def wait_for(configured)
        return 0 if @park && context&.inline_async_execution

        configured
      end

      def key_for(config)
        StepCoordination.resolve_key(config, arguments, step_name)
      end

      def step_name
        if context.is_a?(RubyReactor::Context)
          context.current_step || step_config.name.to_s
        else
          step_config.name
        end
      end

      # Stash identity for every parked marker (lock, semaphore, rate-limit
      # charge, ordered-lock nonce). Normally just `step_name` — but a nested
      # direct `InnerStep.run(args, context)` inside an outer step shares that
      # step's `current_step`, so the name alone would let the outer scope's
      # marker overwrite the inner one: on redelivery the inner lock is
      # acquired again under the same owner (bumping its Redis reentrancy
      # count) and released only once, leaking the key. Nested scopes on the
      # same step therefore get a depth suffix, which replays identically on
      # the redelivery because the nesting order is the code's, not a race's.
      def marker_name
        @marker_name ||= begin
          base = step_name.to_s
          depth = open_scopes.count { |n| n == base || n.start_with?("#{base}#") }
          depth.zero? ? base : "#{base}##{depth}"
        end
      end

      def open_scopes
        Thread.current[SCOPE_KEY] ||= []
      end

      # Marker identity is fixed on entry, before this scope is itself counted.
      def enter_scope
        open_scopes.push(marker_name)
      end

      def leave_scope
        idx = open_scopes.rindex(marker_name)
        open_scopes.delete_at(idx) if idx
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
