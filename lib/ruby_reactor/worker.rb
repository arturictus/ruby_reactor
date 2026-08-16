# frozen_string_literal: true

module RubyReactor
  # Framework-agnostic resume/snooze/escalate logic shared by every queueing
  # backend's worker class. Each backend (`Adapters::Sidekiq::Worker`,
  # `Adapters::ActiveJob::Worker`, ...) includes this and supplies its own
  # `self.class.perform_in` (native on Sidekiq::Worker, via
  # `Adapters::ActiveJob::Compat` on ActiveJob::Base) — nothing here references
  # a specific backend.
  module Worker
    # Identity-only payload: storage is the source of truth. Rehydrate the live
    # context from storage by id, then resume. A nil read means the context was
    # swept, expired, or already terminal-and-collected — nothing to resume.
    def perform(context_id, reactor_class_name = nil, snooze_count = 0)
      # Normalize so a nil/omitted name resolves to the same storage key the
      # enqueue path wrote (always via reactor_storage_name). Without this a
      # nil here builds "reactor::context:<id>" and misses the stored
      # "reactor:AnonymousReactor:context:<id>", silently no-op'ing.
      reactor_class_name ||= RubyReactor.reactor_storage_name(nil)
      data = RubyReactor.configuration.storage_adapter.retrieve_context(context_id, reactor_class_name)
      return if data.nil?

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

      # Mark that we're executing inline to prevent nested async calls
      context.inline_async_execution = true

      begin
        # Resume execution from the failed step
        executor = Executor.new(context.reactor_class, {}, context)
        executor.resume_execution
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
             RubyReactor::OrderedLock::WaitError => e
        # Snooze on expected concurrency, rate, or ordering contention.
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

    private

    # If reactor_class_name is provided, use it to get the reactor class.
    # This handles cases where the class can't be found via const_get.
    def resolve_reactor_class!(context, reactor_class_name)
      return unless reactor_class_name && context.reactor_class.nil?

      begin
        context.reactor_class = Object.const_get(reactor_class_name)
      rescue NameError
        # If not found, try to find it in the current namespace
        # This is a fallback for test environments
        context.reactor_class = reactor_class_name.constantize if reactor_class_name.respond_to?(:constantize)
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
      capped = !(error.is_a?(RubyReactor::OrderedLock::WaitError) ||
                 error.is_a?(RubyReactor::Lock::ContextLockContention))

      if capped && max != :infinity && snooze_count >= max
        escalate_snooze(context, snooze_count, error)
        return
      end

      delay = compute_snooze_delay(config, error)
      # Re-enqueue by id: the context is already persisted in storage, so the
      # rescheduled job rehydrates fresh state (no stale blob).
      self.class.perform_in(delay, context_id, reactor_class_name, snooze_count + 1)
    end

    # Use the error's `retry_after_seconds` hint when available
    # (RateLimit::ExceededError carries the time until the bucket rolls);
    # otherwise fall back to the configured base + jitter for lock/semaphore
    # contention which has no precise hint.
    #
    # OrderedLock::WaitError is deliberately excluded from the hint path: its
    # `retry_after_seconds` is the poison-pill window (the upper bound before
    # a *dead* blocker is force-advanced), NOT how long the *live* blocker
    # will take — which is usually milliseconds. Snoozing for the full window
    # would make every out-of-order nonce sleep up to poison_pill_timeout even
    # though its blocker finishes immediately, collapsing throughput. Re-poll
    # at the base delay instead; poison auto-advance still clears a genuinely
    # dead blocker on a later gate.
    def compute_snooze_delay(config, error)
      jitter = config.lock_snooze_jitter.to_f
      jitter_amount = jitter.positive? ? rand(0.0..jitter) : 0.0

      if hinted_retry?(error)
        [error.retry_after_seconds.to_f, 0.1].max + jitter_amount
      else
        config.lock_snooze_base_delay.to_f + jitter_amount
      end
    end

    def hinted_retry?(error)
      return false if error.is_a?(RubyReactor::OrderedLock::WaitError)

      error.respond_to?(:retry_after_seconds) && error.retry_after_seconds
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
