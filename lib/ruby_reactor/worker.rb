# frozen_string_literal: true

module RubyReactor
  # Framework-agnostic resume/snooze/escalate logic shared by every queueing
  # backend's worker class. Each backend (`Adapters::Sidekiq::Worker`,
  # `Adapters::ActiveJob::Worker`, ...) includes this and supplies its own
  # `self.class.perform_in` (native on Sidekiq::Worker, via
  # `Adapters::ActiveJob::Compat` on ActiveJob::Base) — nothing here references
  # a specific backend.
  module Worker
    TERMINAL_STATUSES = %w[completed failed cancelled skipped halted aborted].freeze

    # Seconds a Worker waits for the run's lock before it reads the run (010
    # R-02). The usual holder is the caller that enqueued this job, a few
    # milliseconds from its final save and release; a snooze would cost a whole
    # scheduled-set poll instead. Same bound as `Map::Collector::COLLECT_LOCK_WAIT`.
    CONTEXT_LOCK_WAIT = 2

    # Use the error's `retry_after_seconds` hint when available
    # (RateLimit::ExceededError carries the time until the bucket rolls);
    # otherwise fall back to the configured base + jitter for lock/semaphore
    # contention which has no precise hint. Module-level (not just an
    # instance method) so `StepCoordination::Contended` — which wraps a
    # contention error but is not itself a snooze-worthy reactor-level
    # error — can reuse the identical hint logic from the async_step worker
    # (T036) without including this whole module.
    #
    # OrderedLock::WaitError is deliberately excluded from the hint path: its
    # `retry_after_seconds` is the poison-pill window (the upper bound before
    # a *dead* blocker is force-advanced), NOT how long the *live* blocker
    # will take — which is usually milliseconds. Snoozing for the full window
    # would make every out-of-order nonce sleep up to poison_pill_timeout even
    # though its blocker finishes immediately, collapsing throughput. Re-poll
    # at the base delay instead; poison auto-advance still clears a genuinely
    # dead blocker on a later gate.
    def self.snooze_delay(config, error)
      jitter = config.lock_snooze_jitter.to_f
      jitter_amount = jitter.positive? ? rand(0.0..jitter) : 0.0

      if hinted_retry?(error)
        [error.retry_after_seconds.to_f, 0.1].max + jitter_amount
      else
        config.lock_snooze_base_delay.to_f + jitter_amount
      end
    end

    def self.hinted_retry?(error)
      # `StepCoordination::Contended` wraps the WaitError as `.original` —
      # unwrap so the same exclusion applies whether the caller is the
      # reactor-level ordered lock (raises WaitError directly) or a step's
      # (raises Contended, whose OWN `retry_after_seconds` just forwards the
      # wrapped error's hint unchanged).
      original = error.respond_to?(:original) ? error.original : error
      return false if original.is_a?(RubyReactor::OrderedLock::WaitError)

      error.respond_to?(:retry_after_seconds) && error.retry_after_seconds
    end

    # Last line of observability when a job burns its whole retry budget on an
    # infrastructure failure and the backend then discards it (Sidekiq runs
    # with `dead: false`): without this, the context would stay "running"
    # forever with zero surface anywhere, and every reader would wait out its
    # full timeout. Called from the backends' retries-exhausted hooks with the
    # job's own args. Best-effort — never raises back into the backend.
    def self.record_retries_exhausted(args, exception)
      context_id, reactor_class_name = args
      return unless context_id

      reactor_class_name ||= RubyReactor.reactor_storage_name(nil)
      storage = RubyReactor.configuration.storage_adapter
      data = storage.retrieve_context(context_id, reactor_class_name)
      return if data.nil? || TERMINAL_STATUSES.include?((data["status"] || data[:status]).to_s)

      data["status"] = "failed"
      data["failure_reason"] = {
        "message" => "job retries exhausted: #{exception.class.name}: #{exception.message}",
        "exception_class" => exception.class.name
      }
      storage.store_context(context_id, JSON.generate(data), reactor_class_name)
      storage.publish(RubyReactor.async_reactor_channel(context_id), "failed")
    rescue StandardError => e
      RubyReactor.configuration.logger.error(
        "RubyReactor: could not record retries-exhausted failure for #{context_id}: #{e.class.name}: #{e.message}"
      )
    end

    # Identity-only payload: storage is the source of truth. Rehydrate the live
    # context from storage by id, then resume. A nil read means the context was
    # swept, expired, or already terminal-and-collected — nothing to resume.
    #
    # Lock, then load (010 R-02, J-2): the run's `async:` lock is taken BEFORE
    # the read, so this job sees the last save of whoever held it — a caller
    # that just handed off, a manual undo, another worker — and its own later
    # save can never replace newer progress. The executor re-enters the lock.
    def perform(context_id, reactor_class_name = nil, snooze_count = 0)
      # Normalize so a nil/omitted name resolves to the same storage key the
      # enqueue path wrote (always via reactor_storage_name). Without this a
      # nil here builds "reactor::context:<id>" and misses the stored
      # "reactor:AnonymousReactor:context:<id>", silently no-op'ing.
      reactor_class_name ||= RubyReactor.reactor_storage_name(nil)
      lock = lock_run(context_id, reactor_class_name, snooze_count)
      return if lock == :snoozed

      begin
        perform_locked(context_id, reactor_class_name, snooze_count, lock&.owner)
      ensure
        lock&.release
      end
    end

    private

    # nil in inline job-testing mode, where a nested re-entry would contend
    # with itself (as `Executor#acquire_context_lock`). Another live holder
    # after the wait: snooze, uncapped, having read and written nothing.
    def lock_run(context_id, reactor_class_name, snooze_count)
      return nil if inline_testing_mode?

      lock = RubyReactor::Lock.new("async:#{context_id}", owner: SecureRandom.uuid,
                                                          ttl: RubyReactor.configuration.context_lock_ttl,
                                                          wait: CONTEXT_LOCK_WAIT, auto_extend: true)
      lock.acquire
      lock
    rescue RubyReactor::Lock::AcquisitionError => e
      contention = RubyReactor::Lock::ContextLockContention.new(e.message, context_lock_key: "async:#{context_id}")
      handle_snooze(context_id, reactor_class_name, nil, snooze_count, contention)
      :snoozed
    end

    def inline_testing_mode?
      defined?(::Sidekiq::Testing) && ::Sidekiq::Testing.respond_to?(:inline?) && ::Sidekiq::Testing.inline?
    end

    def perform_locked(context_id, reactor_class_name, snooze_count, lock_owner)
      data = RubyReactor.configuration.storage_adapter.retrieve_context(context_id, reactor_class_name)
      return if data.nil?

      status = (data["status"] || data[:status]).to_s
      # Finished, cancelled or aborted: nothing to resume (an aborted run takes
      # only a manual undo, 008 R-08). A stray or duplicate job does nothing.
      return if TERMINAL_STATUSES.include?(status)

      begin
        context = ContextSerializer.deserialize_hash(data)
      rescue RubyReactor::Error::DeserializationError,
             RubyReactor::Error::SchemaVersionError => e
        # Permanent failures — re-reading the same stored blob will keep
        # failing. Mark the context as failed (best-effort) and return so
        # the job does not burn its retry budget.
        handle_deserialization_failure(context_id, reactor_class_name, e)
        return
      end

      resolve_reactor_class!(context, reactor_class_name)
      unless context.reactor_class
        # Still unresolved (class not loaded, or an anonymous reactor with no
        # storage name to look up) — Executor.new below would blow up on a nil
        # class and burn the job's retry budget forever. Fail the context now.
        error = RubyReactor::Error::DeserializationError.new(
          "reactor class '#{reactor_class_name}' could not be resolved"
        )
        handle_deserialization_failure(context_id, reactor_class_name, error)
        return
      end

      # A paused run advances only with a claimed payload (010 R-06): a stray
      # job must never run the steps that follow the interrupt without one.
      return if status == "paused" && InterruptClaims.unapplied(context).empty?

      # Mark that we're executing inline to prevent nested async calls
      context.inline_async_execution = true

      begin
        # Resume execution from the failed step — or, for a run whose rollback
        # handed off at a fan-out map, finish that rollback (009 R-04).
        executor = Executor.new(context.reactor_class, {}, context)
        executor.context_lock_owner = lock_owner
        rolling_back = status == "rolling_back"
        rolling_back ? executor.resume_rollback : executor.resume_execution
        # No explicit save here: resume_execution's ensure block already persists
        # the final root state (`save_context unless skip_context_persist?`), and
        # in the worker the executor's context IS the root, so an extra checkpoint!
        # would just re-write the identical blob to the identical key. The
        # skip_context_persist? guard (stale-batch redelivery of an already-terminal
        # context) is likewise honored there.

        # Return the executor (which now has the result stored in it)
        executor
      rescue RubyReactor::Lock::AcquisitionError,
             RubyReactor::Semaphore::AcquisitionError,
             RubyReactor::RateLimit::ExceededError,
             RubyReactor::OrderedLock::WaitError,
             RubyReactor::Error::ExecutionParked => e
        # Snooze on expected concurrency, rate, or ordering contention, or on
        # a park signal (a step's contention, or an awaited background result)
        # — raised at any nesting depth, after every executor on the stack has
        # parked its own holds and saved.
        # OrderedLock::WaitError carries a poison-pill-derived retry hint,
        # consumed by compute_snooze_delay below. We avoid the framework's native
        # retry path so this doesn't burn the job's retry budget or appear
        # as an error in dashboards. After the configured cap is reached we
        # escalate by marking the reactor as failed.
        handle_snooze(context_id, reactor_class_name, context, snooze_count, e)
      rescue RubyReactor::RateLimitRegistry::UnknownLimitError => e
        # Permanent configuration error — snoozing or retrying the same job
        # will keep failing. Mark the context failed immediately.
        escalate_snooze(context, snooze_count, e)
      end
    end

    # If reactor_class_name is provided, use it to get the reactor class.
    # This handles cases where the class can't be found via const_get.
    def resolve_reactor_class!(context, reactor_class_name)
      return unless reactor_class_name && context.reactor_class.nil?

      begin
        context.reactor_class = Object.const_get(reactor_class_name)
      rescue NameError
        # If not found, try to find it in the current namespace
        # This is a fallback for test environments
        begin
          context.reactor_class = reactor_class_name.constantize if reactor_class_name.respond_to?(:constantize)
        rescue NameError
          # Leave reactor_class nil: the caller's guard fails the context with
          # a durable record. Letting this second NameError escape would burn
          # the job's whole retry budget on an error retries can never fix,
          # then vanish — leaving the context "running" forever and any reader
          # waiting out its full timeout.
          nil
        end
      end
    end

    def handle_snooze(context_id, reactor_class_name, context, snooze_count, error)
      config = RubyReactor.configuration
      max = config.lock_snooze_max_attempts

      # OrderedLock::WaitError bypasses the snooze cap. The gate's
      # poison_pill_timeout is the only meaningful upper bound on how long a
      # nonce can legitimately wait; capping snoozes would either fail jobs
      # prematurely or strand the nonce in `assigned_at` until poison_pill
      # eventually advances past it. Snooze until the gate passes (or poison
      # auto-advance moves the cursor past us).
      # The per-context liveness lock (`async:<id>`) is also uncapped: a
      # duplicate of the *same* execution may wait arbitrarily long for the
      # live original to finish (e.g. a sweeper re-enqueue racing a slow but
      # alive worker). Capping it would fail a legitimately-waiting duplicate.
      # A park signal is likewise uncapped HERE, bounded where it is raised:
      # an async wait by `async_park_timeout` against `dispatched_at`, a
      # step's contention by `lock_snooze_max_attempts` on that step's own
      # contention counter (`StepExecutor#handle_contention`) — counting
      # snoozes too would double-bound either with the wrong unit.
      capped = !(error.is_a?(RubyReactor::OrderedLock::WaitError) ||
                 error.is_a?(RubyReactor::Lock::ContextLockContention) ||
                 error.is_a?(RubyReactor::Error::ExecutionParked))

      # Escalation marks the run `failed` WITHOUT rolling back: harmless before
      # admission, when nothing ran, but a run already admitted (a resume,
      # deferred or `resume: :background`, or a re-entry after a hand-off) has
      # completed steps whose effects would be stranded. It keeps waiting
      # instead, and says so once (010 R-07, J-8).
      if capped && context&.admitted?
        warn_still_waiting(context, snooze_count, error) if max != :infinity && snooze_count == max
        capped = false
      end

      if capped && max != :infinity && snooze_count >= max
        escalate_snooze(context, snooze_count, error)
        return
      end

      delay = compute_snooze_delay(config, error)
      # Re-enqueue by id: the context is already persisted in storage, so the
      # rescheduled job rehydrates fresh state (no stale blob).
      self.class.perform_in(delay, context_id, reactor_class_name, snooze_count + 1)
    end

    def warn_still_waiting(context, snooze_count, error)
      fields = { event: "ruby_reactor.resume.waiting", reactor: RubyReactor.reactor_storage_name(context.reactor_class),
                 context_id: context.context_id, error: error.message, snooze_count: snooze_count }
      RubyReactor.configuration.logger.warn(fields.map { |k, v| "#{k}=#{v.inspect}" }.join(" "))
    end

    # Instance methods delegate to the module functions above — worker
    # behavior is unchanged, just relocated so other callers (StepWorker,
    # T036) can reuse the same logic without a Worker instance.
    def compute_snooze_delay(config, error)
      Worker.snooze_delay(config, error)
    end

    def hinted_retry?(error)
      Worker.hinted_retry?(error)
    end

    def escalate_snooze(context, snooze_count, error)
      RubyReactor.configuration.logger.warn(
        "RubyReactor snooze limit reached after #{snooze_count} attempts " \
        "for context #{context.context_id}: #{error.message}"
      )

      context.status = :failed
      context.failure_reason = {
        message: error.message,
        exception_class: error.class.name,
        snooze_attempts: snooze_count
      }

      serialized = ContextSerializer.serialize(context)
      reactor_class_name = RubyReactor.reactor_storage_name(context.reactor_class)
      RubyReactor.configuration.storage_adapter.store_context(
        context.context_id,
        serialized,
        reactor_class_name
      )

      # Escalation is a terminal Failure that never reaches the Executor's
      # ensure path, so advance the ordered-lock cursor here. Without this
      # the nonce stays stranded in assigned_at (successors stall for the
      # full poison_pill_timeout) and, worse, the strict-mode chain marker
      # is never recorded — successors would RUN instead of being skipped.
      info = Executor::OrderedLockSupport.info_from(context)
      Executor::OrderedLockSupport.advance_with_retry(info, failed: true) if info
    end

    def log_infrastructure_failure(msg, exception)
      RubyReactor.configuration.logger.error("RubyReactor infrastructure failure: #{exception.message}")
      RubyReactor.configuration.logger.error("Job details: #{msg.inspect}")
    end

    # The id-only payload already carries context_id and reactor_class_name, so
    # there is no blob to parse for metadata — just mark the stored context
    # failed (best-effort) so the job stops retrying a permanently-broken blob.
    def handle_deserialization_failure(context_id, reactor_class_name, error)
      RubyReactor.configuration.logger.error(
        "RubyReactor deserialization failure for context " \
        "#{context_id || "unknown"}: #{error.class.name}: #{error.message}"
      )

      return unless context_id && reactor_class_name

      payload = build_failed_context_payload(context_id, reactor_class_name, error)
      RubyReactor.configuration.storage_adapter.store_context(
        context_id,
        payload,
        reactor_class_name
      )
      # Written first, signalled second — wake any reader blocked (or parked)
      # on this execution so it fails fast with the real cause instead of
      # waiting out its timeout.
      RubyReactor.configuration.storage_adapter.publish(
        RubyReactor.async_reactor_channel(context_id), "failed"
      )
    rescue StandardError => e
      # Don't let a persistence failure mask the original deserialization error.
      RubyReactor.configuration.logger.error(
        "RubyReactor failed to persist deserialization failure: #{e.class.name}: #{e.message}"
      )
    end

    def build_failed_context_payload(context_id, reactor_class_name, error)
      JSON.generate(
        "schema_version" => ContextSerializer::SCHEMA_VERSION,
        "context_id" => context_id,
        "reactor_class" => reactor_class_name,
        "status" => "failed",
        "failure_reason" => {
          "message" => error.message,
          "exception_class" => error.class.name
        }
      )
    end
  end
end
