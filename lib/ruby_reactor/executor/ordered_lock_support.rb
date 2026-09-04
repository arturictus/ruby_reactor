# frozen_string_literal: true

module RubyReactor
  class Executor
    # Gate check and terminal-advance logic for `with_ordered_lock`. Mixed
    # into Executor to keep that class under the length limit. All methods
    # read from `@context.private_data[:ordered_lock]`, which Reactor#run
    # populates at enqueue time.
    module OrderedLockSupport
      # Thread-local stack of ordered-lock keys whose steps are currently
      # running in this thread. Used to detect a synchronous `Reactor.run`
      # nested under another ordered-lock reactor on the same key — which
      # would deadlock since the outer holds the slot and the inner can never
      # advance.
      THREAD_LOCAL_ACTIVE_KEYS = :ruby_reactor_active_ordered_locks

      # Minimum interval between liveness heartbeats; protects very small
      # poison_pill_timeouts (mirrors Lock::MIN_EXTEND_INTERVAL).
      HEARTBEAT_MIN_INTERVAL = 1.0

      def self.active_keys
        Thread.current[THREAD_LOCAL_ACTIVE_KEYS] ||= []
      end

      # Parse the ordered-lock stash from a context's private_data, surviving
      # the JSON round-trip (symbol or string keys). Module-level so the
      # Sidekiq worker can advance the nonce on escalation paths that never
      # construct an Executor.
      def self.info_from(context)
        data = context.private_data[:ordered_lock] || context.private_data["ordered_lock"]
        return nil unless data

        strict_raw = data[:strict]
        strict_raw = data["strict"] if strict_raw.nil?
        strict_raw = true if strict_raw.nil?

        {
          key: data[:key] || data["key"],
          nonce: (data[:nonce] || data["nonce"]).to_i,
          epoch: (data[:epoch] || data["epoch"]).to_i,
          poison_pill_timeout: (data[:poison_pill_timeout] || data["poison_pill_timeout"] ||
                                OrderedLock::DEFAULT_POISON_PILL_TIMEOUT).to_i,
          ttl: (data[:ttl] || data["ttl"] || OrderedLock::DEFAULT_TTL).to_i,
          strict: [true, "true"].include?(strict_raw)
        }
      end

      # Strict-ordering gate. Runs BEFORE rate-limit / lock / semaphore so a
      # waiting nonce never holds any other primitive — preventing
      # hold-and-wait deadlocks when `with_lock` and `with_ordered_lock`
      # share inputs. Raises {OrderedLock::WaitError}; the Sidekiq worker
      # rescues and snoozes.
      def check_ordered_lock_gate
        info = ordered_lock_info
        return :go unless info

        OrderedLock.new(
          info.fetch(:key),
          nonce: info.fetch(:nonce),
          epoch: info.fetch(:epoch),
          poison_pill_timeout: info.fetch(:poison_pill_timeout),
          strict: info.fetch(:strict)
        ).check!
      end

      # Combined gate-check + thread-local push. Call at the top of
      # `execute` / `resume_execution`. Pair with `leave_ordered_lock_scope`
      # in `ensure`.
      #
      # The strict-mode chain-skip only fires on a *fresh* start (no step
      # has run yet on this context). This lets an in-flight run that paused
      # (Interrupt / DispatchResult) complete on resume regardless of chain
      # failures that landed while it was parked, while still applying
      # strict to a fresh Sidekiq job (which enters via `resume_execution`
      # but has no prior step state).
      def enter_ordered_lock_scope
        gate = check_ordered_lock_gate
        # A stale-batch run never participates regardless of fresh/resume state —
        # its numbering belongs to a drained generation. Chain-skip stays gated
        # on a fresh start so an in-flight paused run still completes on resume.
        @ordered_lock_stale_batch = gate == :stale_batch
        @ordered_lock_chain_skip = fresh_ordered_lock_start? && gate == :skip_chain_failed

        # Drained-batch gate: the batch GC'd while this caller slept. A genuine
        # late straggler runs (poison semantics); a Sidekiq redelivery of an
        # ALREADY-terminal context must not re-execute its steps. Only the
        # latter — confirmed by a terminal stored status — is short-circuited.
        @ordered_lock_drained_replay = gate == :drained_go && stored_status_terminal?

        info = ordered_lock_info
        return unless info

        OrderedLockSupport.active_keys << info[:key]

        # Only a run that will actually execute steps needs a heartbeat. A
        # short-circuiting run (stale batch / strict chain skip / drained
        # redelivery) does no work and terminally advances immediately, so
        # starting a thread for it is pointless churn.
        return if @ordered_lock_stale_batch || @ordered_lock_chain_skip || @ordered_lock_drained_replay

        start_ordered_lock_heartbeat(info)
      end

      def fresh_ordered_lock_start?
        @context.intermediate_results.empty? && @context.current_step.nil?
      end

      def ordered_lock_chain_skip?
        @ordered_lock_chain_skip == true
      end

      def ordered_lock_stale_batch?
        @ordered_lock_stale_batch == true
      end

      def ordered_lock_drained_replay?
        @ordered_lock_drained_replay == true
      end

      # Terminal Skipped result when the ordered-lock gate short-circuits this
      # run (stale batch, strict chain failure, or a drained-batch redelivery of
      # an already-terminal context), or nil to continue. Shared by `execute`
      # and `resume_execution`.
      def ordered_lock_short_circuit
        return RubyReactor::Skipped.new(reason: :ordered_lock_stale_batch) if ordered_lock_stale_batch?
        return RubyReactor::Skipped.new(reason: :ordered_lock_drained_replay) if ordered_lock_drained_replay?
        return RubyReactor::Skipped.new(reason: :ordered_lock_chain_failed) if ordered_lock_chain_skip?

        nil
      end

      # Pre-step short-circuit: ordered-lock gate skip or already-marked
      # period bucket. Returns a terminal result or nil.
      def short_circuit_result
        ordered_lock_short_circuit || check_period_gate
      end

      def short_circuit!(result)
        @result = result

        # A stale-batch or drained-batch-redelivery skip means this run's epoch
        # belongs to a drained generation — typically a slow straggler or a
        # Sidekiq at-least-once redelivery. If the redelivery is of a job that
        # ALREADY reached a terminal status, its stored context is the source of
        # truth; writing :skipped over a :completed/:failed record would silently
        # corrupt the outcome. Return the skip to the worker (so it stops)
        # without saving. The `@skip_context_persist` flag also suppresses the
        # ensure-block save in execute / resume_execution, which would otherwise
        # clobber the stored terminal record with this run's stale in-memory
        # status.
        if redelivery_of_terminal?(result)
          @skip_context_persist = true
          return @result
        end

        update_context_status(@result)
        save_context
        @result
      end

      def skip_context_persist?
        @skip_context_persist == true
      end

      # True when the skip is one of the drained-generation reasons (stale batch
      # or drained-batch replay) AND the stored context already reached a
      # terminal status — i.e. this is a redelivery of an already-finished run
      # whose record must not be overwritten. The drained-replay flag is only
      # set when the status was terminal, but re-checking keeps both paths
      # uniform and self-guarding.
      def redelivery_of_terminal?(result)
        return false unless result.is_a?(RubyReactor::Skipped)
        return false unless %i[ordered_lock_stale_batch ordered_lock_drained_replay].include?(result.reason)

        stored_status_terminal?
      end

      def stored_status_terminal?
        %w[completed failed skipped].include?(stored_context_status)
      end

      def stored_context_status
        reactor_class_name = RubyReactor.reactor_storage_name(@reactor_class)
        data = RubyReactor.configuration.storage_adapter.retrieve_context(@context.context_id, reactor_class_name)
        return nil unless data

        (data["status"] || data[:status]).to_s
      rescue StandardError
        nil
      end

      # Combined terminal-advance + thread-local pop. Idempotent: safe to call
      # in `ensure` even if `enter_ordered_lock_scope` never pushed (gate
      # raised, or no ordered_lock configured).
      def leave_ordered_lock_scope
        # Stop (and join) the heartbeat BEFORE advancing: the advance HDELs this
        # nonce's assigned_at, and a heartbeat racing that HDEL could restamp it.
        # The HEARTBEAT_SCRIPT's hexists guard makes a late restamp a harmless
        # no-op, but joining first keeps the ordering deterministic.
        stop_ordered_lock_heartbeat
        advance_ordered_lock_if_terminal
        info = ordered_lock_info
        return unless info

        stack = OrderedLockSupport.active_keys
        idx = stack.rindex(info[:key])
        stack.delete_at(idx) if idx
      end

      # Background thread that restamps this nonce's assigned_at every pp/3
      # seconds (floored at HEARTBEAT_MIN_INTERVAL) while its steps run, so a
      # legitimately slow blocker is not poison-passed by a successor. Mirrors
      # the Lock auto-extend thread. The thread sleeps FIRST, so a job that
      # finishes faster than one interval never touches Redis.
      def start_ordered_lock_heartbeat(info)
        return if @ordered_lock_heartbeat_running

        pp = info[:poison_pill_timeout].to_f
        interval = [pp / 3.0, HEARTBEAT_MIN_INTERVAL].max
        @ordered_lock_heartbeat_running = true
        lock = OrderedLock.new(
          info.fetch(:key), nonce: info.fetch(:nonce), epoch: info.fetch(:epoch)
        )

        @ordered_lock_heartbeat = Thread.new do
          while @ordered_lock_heartbeat_running
            sleep interval
            break unless @ordered_lock_heartbeat_running

            begin
              lock.heartbeat!
            rescue StandardError => e
              RubyReactor.configuration.logger.warn(
                "RubyReactor ordered_lock heartbeat failed for '#{info[:key]}' " \
                "nonce #{info[:nonce]}: #{e.message}"
              )
              break
            end
          end
        end
      end

      def stop_ordered_lock_heartbeat
        return unless @ordered_lock_heartbeat_running

        @ordered_lock_heartbeat_running = false
        thread = @ordered_lock_heartbeat
        @ordered_lock_heartbeat = nil
        return unless thread

        thread.wakeup if thread.alive?
        thread.join(0.1)
      rescue StandardError
        # Best-effort shutdown; never let heartbeat teardown break the ensure chain.
      end

      # Advance the cursor when this run reached a *terminal* status.
      # Retry-queued, interrupted, or async-handed-off results keep the same
      # nonce owning the slot — a Sidekiq retry must not double-advance. A
      # terminal `Failure` is also recorded as the chain's poison marker
      # (only the FIRST such failure sticks).
      def advance_ordered_lock_if_terminal
        info = ordered_lock_info
        return unless info
        return unless terminal_for_ordered_lock?(@result)

        OrderedLockSupport.advance_with_retry(info, failed: @result.is_a?(RubyReactor::Failure))
      end

      # A missed advance on a terminal result stalls every successor for up to
      # poison_pill_timeout with only a warn line as evidence, so one transient
      # Redis blip is worth absorbing here before giving up.
      def self.advance_with_retry(info, failed:)
        attempts = 0
        begin
          attempts += 1
          OrderedLock.new(
            info.fetch(:key), nonce: info.fetch(:nonce), epoch: info.fetch(:epoch), ttl: info.fetch(:ttl)
          ).advance!(failed: failed)
        rescue StandardError => e
          retry if attempts < 2

          RubyReactor.configuration.logger.warn(
            "RubyReactor failed to advance ordered_lock '#{info[:key]}' nonce #{info[:nonce]} " \
            "after #{attempts} attempts: #{e.message} — successors will stall until " \
            "poison_pill_timeout (#{info[:poison_pill_timeout]}s) expires"
          )
        end
      end

      private

      def ordered_lock_info
        OrderedLockSupport.info_from(@context)
      end

      def terminal_for_ordered_lock?(result)
        case result
        when RubyReactor::DispatchResult, RubyReactor::InterruptResult, RetryQueuedResult
          false
        when RubyReactor::Success, RubyReactor::Failure
          true
        end
      end
    end
  end
end
