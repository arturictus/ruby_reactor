# frozen_string_literal: true

require "English"
require_relative "executor/input_validator"
require_relative "executor/graph_manager"
require_relative "executor/retry_manager"
require_relative "executor/compensation_manager"
require_relative "executor/result_handler"
require_relative "executor/async_step_dispatch"
require_relative "executor/step_executor"
require_relative "executor/ordered_lock_support"

module RubyReactor
  # rubocop:disable Metrics/ClassLength
  class Executor
    include OrderedLockSupport

    attr_reader :reactor_class, :context, :dependency_graph, :compensation_manager, :retry_manager, :result_handler,
                :step_executor, :result, :middlewares

    def initialize(reactor_class, inputs = {}, context = nil)
      @reactor_class = reactor_class
      @context = context || Context.new(inputs, reactor_class)
      @middlewares = Executor.middlewares_for(reactor_class)
      @context.middlewares = @middlewares
      @dependency_graph = DependencyGraph.new
      @compensation_manager = CompensationManager.new(@context)
      @retry_manager = RetryManager.new(@context, @middlewares)
      @result_handler = ResultHandler.new(
        context: @context,
        compensation_manager: @compensation_manager,
        dependency_graph: @dependency_graph
      )
      @step_executor = StepExecutor.new(
        context: @context,
        dependency_graph: @dependency_graph,
        reactor_class: @reactor_class,
        managers: {
          retry_manager: @retry_manager,
          result_handler: @result_handler,
          compensation_manager: @compensation_manager,
          middlewares: @middlewares,
          # Save-per-step durable checkpoint. checkpoint! resolves the ROOT
          # context, so this same callback — wired into every executor including
          # the nested ones ComposeStep builds — always advances the root blob
          # (F8): a mid-child crash re-runs one sub-step, not the whole child.
          # `throttle: true` lets checkpoint_min_interval coalesce these mid-run
          # writes (default 0 = write every step); the terminal save still runs.
          on_step_complete: -> { checkpoint!(throttle: true) }
        }
      )
      @result = nil
      @acquired_lock = nil
      @acquired_semaphore = nil
      @acquired_context_lock = nil
      @context_lock_owner = nil
      @contention_snooze = false
      @skip_context_persist = false
      @last_checkpoint_at = nil
    end

    def self.resolve_middlewares(reactor_class)
      global_list = Array(RubyReactor.configuration.middlewares)
      reactor_list = if reactor_class.respond_to?(:middlewares)
                       Array(reactor_class.middlewares)
                     else
                       []
                     end

      (global_list + reactor_list).map do |mw|
        if mw.is_a?(Class)
          mw.new
        elsif mw.is_a?(Array) && mw.first.is_a?(Class)
          klass, opts = mw
          klass.new(**(opts || {}))
        else
          mw
        end
      end
    end

    def self.middlewares_for(reactor_class)
      RubyReactor::MiddlewareRunner.new(resolve_middlewares(reactor_class))
    end

    def execute # rubocop:disable Metrics/MethodLength
      middlewares.on(:start_reactor, reactor_class.name, context.inputs, @context)
      completed = false

      enter_ordered_lock_scope
      # short_circuit_result covers both the strict ordered-lock chain skip
      # and the already-marked period bucket.
      short = short_circuit_result
      if short
        completed = true
        return short_circuit!(short)
      end

      # Validate inputs BEFORE consuming a rate-limit slot or grabbing a
      # lock/semaphore: a run that can never start must not burn quota or
      # briefly block other callers.
      input_validator = InputValidator.new(@reactor_class, @context)
      input_validator.validate!

      reset_held_lock_keys!
      acquire_locks_with_telemetry

      # Re-check the period gate now that we hold the lock. The pre-lock check
      # is a fast path; this one closes the race where two callers both passed
      # it and then serialized on the lock — without it the second caller would
      # re-run work the first already marked. (No-op when no lock is configured.)
      if (skipped = check_period_gate)
        completed = true
        return finalize_skipped(skipped)
      end

      @context.status = :running
      save_context

      graph_manager = GraphManager.new(@reactor_class, @dependency_graph, @context)
      graph_manager.build_and_validate!
      graph_manager.mark_completed_steps_from_context

      @result = @step_executor.execute_all_steps
      update_context_status(@result)
      mark_period_on_success(@result)
      handle_interrupt(@result) if @result.is_a?(RubyReactor::InterruptResult)
      completed = true
      @result
    rescue RubyReactor::Lock::AcquisitionError,
           RubyReactor::Semaphore::AcquisitionError,
           RubyReactor::RateLimit::ExceededError,
           RubyReactor::RateLimitRegistry::UnknownLimitError,
           RubyReactor::OrderedLock::WaitError => e
      @contention_snooze = true
      raise e
    rescue StandardError => e
      @result = @result_handler.handle_execution_error(e)
      update_context_status(@result)
      completed = true
      @result
    ensure
      release_locks
      leave_ordered_lock_scope
      save_context if persist_context? && !skip_context_persist?

      emit_lifecycle_completion(completed)
    end

    # Contention errors (lock/semaphore/rate-limit/ordered-lock wait) are
    # expected "try again later" signals, not failures — the worker snoozes
    # and re-runs. Emitting `failed_reactor` for them floods dashboards with
    # phantom failures (one per snooze round), so route them to a distinct
    # `snooze_reactor` event instead.
    def emit_lifecycle_completion(completed)
      if completed
        middlewares.on(:complete_reactor, reactor_class.name, @result, @context)
      elsif @contention_snooze
        middlewares.on(:snooze_reactor, reactor_class.name, $ERROR_INFO, @context)
      else
        middlewares.on(:failed_reactor, reactor_class.name, $ERROR_INFO, @context)
      end
    end

    def resume_execution # rubocop:disable Metrics/MethodLength,Metrics/PerceivedComplexity,Metrics/CyclomaticComplexity
      middlewares.on(:start_reactor, reactor_class.name, context.inputs, @context)
      completed = false

      # A fresh async reactor run reaches the worker through resume_execution
      # (it never calls execute), so the period and rate-limit gates that live
      # in execute must be applied here too. Genuine resumes (a step already ran
      # or we paused mid-flight, so current_step is set) must NOT re-gate: a
      # paused reactor must not throttle or skip itself on the way back in.
      first_run = first_execution?

      enter_ordered_lock_scope
      # ordered-lock skip applies on any run; the period gate only on a fresh
      # first run (a genuine resume must not skip itself when its own marker
      # eventually lands).
      short = ordered_lock_short_circuit
      short ||= check_period_gate if first_run
      if short
        completed = true
        return short_circuit!(short)
      end

      @context.status = :running
      check_rate_limit if first_run

      # Per-context liveness lock: serializes duplicate deliveries of the same
      # root context (e.g. a sweeper re-enqueue racing a still-live worker) and
      # doubles as the sweeper's "worker alive" signal. Only the ROOT executor
      # holds it — composed/nested children resume inline under the root worker
      # and must not contend on the root's own key.
      acquire_context_lock

      reset_held_lock_keys!

      # Resumes intentionally skip check_rate_limit (a paused run must not
      # block itself on resume), so acquire lock/semaphore directly rather
      # than via acquire_locks.
      acquire_exclusive_lock if @reactor_class.respond_to?(:lock_config) && @reactor_class.lock_config
      acquire_semaphore if @reactor_class.respond_to?(:semaphore_config) && @reactor_class.semaphore_config

      # Post-lock re-check (see execute) — closes the period race for the
      # first run of a locked async reactor.
      if first_run && (skipped = check_period_gate)
        completed = true
        return finalize_skipped(skipped)
      end

      prepare_for_resume
      save_context

      @result = if @context.current_step
                  execute_current_step_and_continue
                else
                  execute_remaining_steps
                end

      update_context_status(@result)
      mark_period_on_success(@result)

      handle_interrupt(@result) if @result.is_a?(RubyReactor::InterruptResult)
      completed = true
      @result
    rescue RubyReactor::Lock::AcquisitionError,
           RubyReactor::Semaphore::AcquisitionError,
           RubyReactor::RateLimit::ExceededError,
           RubyReactor::RateLimitRegistry::UnknownLimitError,
           RubyReactor::OrderedLock::WaitError => e
      @contention_snooze = true
      raise e
    rescue StandardError => e
      handle_resume_error(e)
      update_context_status(@result)
      completed = true
      @result
    ensure
      release_locks
      @acquired_context_lock&.release
      @acquired_context_lock = nil
      leave_ordered_lock_scope
      save_context unless skip_context_persist?

      emit_lifecycle_completion(completed)
    end

    def undo_all
      @compensation_manager.rollback_completed_steps
    end

    def undo_stack
      @compensation_manager.undo_stack
    end

    def undo_trace
      @compensation_manager.undo_trace
    end

    def execution_trace
      @context.execution_trace
    end

    def save_context
      storage = RubyReactor::Configuration.instance.storage_adapter
      reactor_class_name = RubyReactor.reactor_storage_name(@reactor_class)

      # Serialize context
      serialized_context = ContextSerializer.serialize(@context)
      storage.store_context(@context.context_id, serialized_context, reactor_class_name)
      publish_completion_signal(storage)
    end

    # Wake any parent blocked in the FR-005 wait on this execution. Published
    # AFTER the durable save, never before: the context row is the answer and
    # the signal only saves the waiter a fallback interval. Unconditional —
    # publishing to a channel with no subscribers is near-free, so there is no
    # need for an "am I awaited?" marker.
    def publish_completion_signal(storage)
      return unless @context.finished?

      log_completion
      storage.publish(RubyReactor.async_reactor_channel(@context.context_id), @context.status.to_s)
    rescue StandardError => e
      # The signal is an optimisation; losing it costs the waiter one fallback
      # interval and must never fail the run that just completed.
      RubyReactor.configuration.logger.warn(
        "RubyReactor: could not publish completion signal for #{@context.context_id}: #{e.message}"
      )
    end

    # Durable per-step checkpoint. Unlike save_context (which serializes THIS
    # executor's @context — the observability path, F1), checkpoint! always
    # serializes and stores the ROOT context under the root's key — the unit the
    # async worker rehydrates by id. For a top-level reactor root == @context; for
    # a composed/nested child it stores the root with the child's live state
    # embedded via composed_contexts. TTL is re-stamped on every write (Phase 4).
    def checkpoint!(throttle: false)
      return if throttle && !checkpoint_due?

      root = @context.root_context || @context
      storage = RubyReactor::Configuration.instance.storage_adapter
      reactor_class_name = RubyReactor.reactor_storage_name(root.reactor_class)
      storage.store_context(root.context_id, ContextSerializer.serialize(root), reactor_class_name)
      @last_checkpoint_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Whether a throttled (per-step) checkpoint is due. With checkpoint_min_interval
    # <= 0 (default) every step checkpoints; otherwise mid-run checkpoints are
    # coalesced to at most one per interval. The first step of a run always writes
    # (@last_checkpoint_at is nil), and the run's terminal save is never throttled.
    def checkpoint_due?
      interval = RubyReactor.configuration.checkpoint_min_interval.to_f
      return true if interval <= 0 || @last_checkpoint_at.nil?

      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @last_checkpoint_at) >= interval
    end

    def persist_context?
      @context.status.to_s != "pending" ||
        @context.execution_trace.any? ||
        @context.intermediate_results.any?
    end

    private

    def acquire_locks
      check_rate_limit
      acquire_concurrency_primitives
    end

    def acquire_concurrency_primitives
      acquire_exclusive_lock if @reactor_class.respond_to?(:lock_config) && @reactor_class.lock_config
      acquire_semaphore if @reactor_class.respond_to?(:semaphore_config) && @reactor_class.semaphore_config
    end

    def acquire_locks_with_telemetry
      acquire_locks
    end

    # Consume one slot from each configured rate-limit window. Raises
    # `RubyReactor::RateLimit::ExceededError` (carrying a `retry_after_seconds`
    # hint) if any window is full. Consulted on the first execution only —
    # `execute` for sync reactors, the first `resume_execution` pass for async
    # reactors. Genuine resumes never re-check (a paused reactor must not block
    # itself on resume).
    def check_rate_limit
      return unless @reactor_class.respond_to?(:rate_limit_config) && @reactor_class.rate_limit_config

      config = @reactor_class.rate_limit_config

      if config[:name]
        # Named global limit: the name is the shared key base and the windows
        # come from the registry (resolved lazily so config order doesn't matter).
        key_base = config[:name].to_s
        limits = RubyReactor.configuration.rate_limits.fetch(config[:name])
      else
        key_base = config[:key_proc].call(@context.inputs)
        limits = config[:limits]
      end

      RubyReactor::RateLimit.new(key_base, limits: limits).check_and_increment!
    end

    # True when nothing has run yet for this context — the very first execution
    # of the reactor, including an async reactor's first worker pass. A genuine
    # resume (paused, async-handed-off, or retried step) always records a
    # `current_step` before serializing, so it is never mistaken for a first run.
    def first_execution?
      @context.current_step.nil? && @context.intermediate_results.empty?
    end

    # Record and persist a Skipped result, then return it. Shared by the
    # pre-lock and post-lock period gates in both execute and resume.
    def finalize_skipped(skipped)
      @result = skipped
      update_context_status(@result)
      save_context
      @result
    end

    # Returns a Skipped result if the period bucket is already marked, else nil.
    # Consulted before AND after lock acquisition on a first execution; genuine
    # resumes never re-check (a paused run must not skip itself when its own
    # marker eventually appears).
    def check_period_gate
      return nil unless @reactor_class.respond_to?(:period_config) && @reactor_class.period_config

      config = @reactor_class.period_config
      key = period_key(config)
      return nil unless RubyReactor.configuration.storage_adapter.period_seen?(key)

      RubyReactor::Skipped.new(reason: :period, period_key: key)
    end

    def mark_period_on_success(result)
      return unless @reactor_class.respond_to?(:period_config) && @reactor_class.period_config
      return unless result.is_a?(RubyReactor::Success)
      return if result.is_a?(RubyReactor::Skipped)

      config = @reactor_class.period_config
      ttl = RubyReactor::Period.ttl_seconds(config[:every])
      RubyReactor.configuration.storage_adapter.period_mark(period_key(config), ttl)
    end

    def period_key(config)
      base = config[:key_proc].call(@context.inputs)
      RubyReactor::Period.key(base, config[:every])
    end

    # FR-012: one machine-parseable line whenever an execution reaches a terminal
    # state, carrying the parent link. A child dispatched fire-and-forget may
    # have no other surface in its parent at all, so a failure entry also names
    # the reason.
    def log_completion
      return unless @context.parent_context_id

      fields = {
        event: "ruby_reactor.async_reactor.completed",
        reactor: @reactor_class&.name,
        execution_id: @context.context_id,
        parent_execution_id: @context.parent_context_id,
        status: @context.status.to_s
      }
      fields[:failure] = failure_summary if @context.failed?

      RubyReactor.configuration.logger.public_send(
        @context.failed? ? :warn : :info,
        fields.map { |k, v| "#{k}=#{v.inspect}" }.join(" ")
      )
    end

    def failure_summary
      reason = @context.failure_reason
      reason.respond_to?(:error) ? reason.error.to_s : reason.to_s
    end

    # Per-execution liveness lock on the root context id. Owner is a fresh UUID
    # per execution (NOT the context_id): a duplicate delivery of the *same*
    # context from a different worker must be blocked, so reentrancy by id would
    # defeat the guard. Only the root executor acquires — a composed/nested child
    # resumes inline under the root worker and shares the root's lock, so it must
    # not try to re-acquire the same key with a different owner (self-deadlock).
    def acquire_context_lock
      root = @context.root_context || @context
      return unless root.equal?(@context) # only the root executor holds it
      # In Sidekiq::Testing.inline! the retry/snooze `perform_in` re-enters the
      # worker synchronously, nested inside this still-running frame that holds
      # the lock — it would self-contend forever. The lock guards concurrent
      # cross-process delivery, which cannot happen under inline testing, so skip.
      return if inline_testing_mode?

      lock = RubyReactor::Lock.new(
        "async:#{root.context_id}",
        owner: @context_lock_owner ||= SecureRandom.uuid,
        ttl: RubyReactor.configuration.context_lock_ttl,
        wait: 0,            # fail fast -> snooze; never block the worker thread
        auto_extend: true   # keep the liveness signal fresh while we run
      )
      lock.acquire
      @acquired_context_lock = lock
    rescue RubyReactor::Lock::AcquisitionError => e
      # We lost the race to a live original holding this context's lock. We did
      # no work, so we must NOT persist on the way out — saving our (older)
      # rehydrated snapshot would clobber the original's newer checkpoint.
      @skip_context_persist = true
      raise RubyReactor::Lock::ContextLockContention.new(e.message, context_lock_key: "async:#{root.context_id}")
    end

    def inline_testing_mode?
      defined?(Sidekiq::Testing) && Sidekiq::Testing.respond_to?(:inline?) && Sidekiq::Testing.inline?
    end

    def acquire_exclusive_lock
      config = @reactor_class.lock_config
      key = config[:key_proc].call(@context.inputs)

      # Use root context ID as owner to allow re-entrancy across nested reactors
      owner = (@context.root_context || @context).context_id

      lock = RubyReactor::Lock.new(
        key,
        owner: owner,
        ttl: config[:ttl],
        wait: contention_wait(config[:wait]),
        auto_extend: config.fetch(:auto_extend, true)
      )
      begin
        lock.acquire
        @acquired_lock = lock
        held_lock_keys << key
        middlewares.on(:lock_acquired, key, @context)
      rescue RubyReactor::Lock::AcquisitionError => e
        middlewares.on(:lock_failed, key, e, @context)
        raise
      end
    end

    def acquire_semaphore
      config = @reactor_class.semaphore_config
      key = config[:key_proc].call(@context.inputs)
      limit = config[:limit]

      semaphore = RubyReactor::Semaphore.new(key, limit: limit, wait: contention_wait(config[:wait]))
      begin
        semaphore.acquire
        @acquired_semaphore = semaphore
        # Only a single-slot semaphore has the circular-wait shape the
        # async_reactor deadlock guard can act on; higher limits are ordinary
        # contention and must keep snoozing.
        held_lock_keys << key if limit == 1
        middlewares.on(:semaphore_acquired, key, limit, @context)
      rescue RubyReactor::Semaphore::AcquisitionError => e
        middlewares.on(:semaphore_failed, key, limit, e, @context)
        raise
      end
    end

    # Inside a Sidekiq worker we'd rather snooze the job via perform_in than
    # tie up the worker thread on a BLPOP / sleep loop. The non-blocking path
    # fails fast and the Worker rescue branch reschedules.
    def contention_wait(configured_wait)
      return 0 if @context.inline_async_execution

      configured_wait
    end

    def release_locks
      if @acquired_semaphore
        key = @acquired_semaphore.key
        release_one("semaphore", @acquired_semaphore)
        held_lock_keys.delete(key)
        middlewares.on(:semaphore_released, key, @context)
      end
      @acquired_semaphore = nil

      return unless @acquired_lock

      key = @acquired_lock.key
      release_one("lock", @acquired_lock)
      held_lock_keys.delete(key)
      @acquired_lock = nil
      middlewares.on(:lock_released, key, @context)
    end

    # Exclusive keys this EXECUTION currently holds, recorded on the root
    # context so a dispatching step anywhere in the tree can see the whole
    # chain. Read by the async_reactor deadlock guard (FR-015); nothing else
    # depends on it, so a stale entry can only cost a false positive — hence
    # the reset on the way in.
    def held_lock_keys
      root = @context.root_context || @context
      root.private_data[:held_lock_keys] ||= []
    end

    # A rehydrated context can carry keys from the process that died holding
    # them. Only the root executor resets, and only on the way in.
    def reset_held_lock_keys!
      return unless (@context.root_context || @context).equal?(@context)

      (@context.root_context || @context).private_data[:held_lock_keys] = []
    end

    def release_one(kind, primitive)
      released = primitive.release
      return if released

      RubyReactor.configuration.logger.warn(
        "RubyReactor #{kind} '#{primitive.key}' was not held at release time " \
        "(likely TTL expired or owner changed)"
      )
    rescue StandardError => e
      # Never let release break the ensure chain — log and move on.
      RubyReactor.configuration.logger.warn(
        "RubyReactor failed to release #{kind} '#{primitive.key}': #{e.message}"
      )
    end

    def update_context_status(result)
      return unless result

      case result
      when RubyReactor::AsyncResult
        @context.status = :running
      when RubyReactor::Skipped
        @context.status = :skipped
      when RubyReactor::Success
        @context.status = :completed
      when RubyReactor::Failure
        @context.status = :failed
        @context.failure_reason = result
      when RubyReactor::InterruptResult
        @context.status = :paused
      end
    end

    def prepare_for_resume
      # Build dependency graph and mark completed steps
      graph_manager = GraphManager.new(@reactor_class, @dependency_graph, @context)
      graph_manager.build_and_validate!
      graph_manager.mark_completed_steps_from_context
    end

    def execute_current_step_and_continue
      step_config = @reactor_class.steps[@context.current_step]
      return RubyReactor::Failure("Step '#{@context.current_step}' not found in reactor") unless step_config

      # If current step is already in intermediate_results, skip directly to execute_all_steps
      return @step_executor.execute_all_steps if @context.intermediate_results.key?(@context.current_step.to_sym)

      # Use execute_step (not execute_step_with_retry) so that async steps can be handled properly in inline mode
      result = @step_executor.execute_step(step_config)

      # execute_step returns nil for inline async, meaning continue execution
      if result.nil?
        @result = @step_executor.execute_all_steps
      else
        case result
        # Skipped must be listed before Success (Skipped < Success) so the
        # halt path wins over the "continue with remaining steps" path.
        when RubyReactor::Skipped,
             RetryQueuedResult,
             RubyReactor::Failure,
             RubyReactor::AsyncResult,
             RubyReactor::InterruptResult
          # Terminal: step was skipped, requeued, failed, paused, or handed
          # off to async. Return the result as-is.
          @result = result
        when RubyReactor::Success
          # Step succeeded, continue with remaining steps
          @result = @step_executor.execute_all_steps
        end
      end
      @result
    end

    def execute_remaining_steps
      @result = @step_executor.execute_all_steps
      @result
    end

    def handle_resume_error(error)
      @result = @result_handler.handle_execution_error(error)
      @result
    end

    def handle_interrupt(interrupt_result)
      save_context

      # Store correlation ID mapping if present
      return unless interrupt_result.correlation_id

      storage = RubyReactor::Configuration.instance.storage_adapter
      storage.store_correlation_id(
        interrupt_result.correlation_id,
        @context.context_id,
        @reactor_class.name
      )
    end
  end
  # rubocop:enable Metrics/ClassLength
end
