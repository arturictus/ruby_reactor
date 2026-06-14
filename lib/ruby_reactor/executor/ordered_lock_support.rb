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
      # (Interrupt / AsyncResult) complete on resume regardless of chain
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

        info = ordered_lock_info
        return unless info

        OrderedLockSupport.active_keys << info[:key]
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

      # Terminal Skipped result when the ordered-lock gate short-circuits this
      # run (stale batch or strict chain failure), or nil to continue. Shared by
      # `execute` and `resume_execution`.
      def ordered_lock_short_circuit
        return RubyReactor::Skipped.new(reason: :ordered_lock_stale_batch) if ordered_lock_stale_batch?
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

        # A stale-batch skip means this run's epoch belongs to a drained
        # generation — typically a slow straggler or a Sidekiq at-least-once
        # redelivery. If the redelivery is of a job that ALREADY reached a
        # terminal status, its stored context is the source of truth; writing
        # :skipped over a :completed/:failed record would silently corrupt the
        # outcome. Return the skip to the worker (so it stops) without saving.
        # The `@skip_context_persist` flag also suppresses the ensure-block save
        # in execute / resume_execution, which would otherwise clobber the
        # stored terminal record with this run's stale in-memory status.
        if stale_batch_redelivery_of_terminal?(result)
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

      def stale_batch_redelivery_of_terminal?(result)
        return false unless result.is_a?(RubyReactor::Skipped) && result.reason == :ordered_lock_stale_batch

        %w[completed failed skipped].include?(stored_context_status)
      end

      def stored_context_status
        reactor_class_name = @reactor_class.name || "AnonymousReactor-#{@reactor_class.object_id}"
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
        advance_ordered_lock_if_terminal
        info = ordered_lock_info
        return unless info

        stack = OrderedLockSupport.active_keys
        idx = stack.rindex(info[:key])
        stack.delete_at(idx) if idx
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
        when RubyReactor::AsyncResult, RubyReactor::InterruptResult, RetryQueuedResult
          false
        when RubyReactor::Success, RubyReactor::Failure
          true
        end
      end
    end
  end
end
