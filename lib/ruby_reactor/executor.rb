# frozen_string_literal: true

require "English"
require_relative "executor/input_validator"
require_relative "executor/graph_manager"
require_relative "executor/retry_manager"
# Before compensation_manager: its NEVER_STARTED_ERROR_CLASSES names
# StepCoordination at load time, while `class Executor` does not exist yet.
require_relative "executor/step_coordination"
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

    # The owner of a run lock (`async:<id>`) the caller already holds: a Worker
    # or `continue` that locked the run before loading it (010 R-02, R-03).
    # `acquire_context_lock` then re-enters it (the lock counts by owner), and
    # the outer holder releases last.
    attr_writer :context_lock_owner

    def initialize(reactor_class, inputs = {}, context = nil)
      # Resume, map, compose and background workers build an Executor without
      # going through Reactor#run; the inferred wiring must exist there too.
      reactor_class.validate_definition! if reactor_class.respond_to?(:validate_definition!)
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
      @parked = false
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

      # A run in the caller's process holds its liveness lock too (010 R-01),
      # so the sweeper never mistakes it for a dead worker's run and a Worker
      # resumed by its hand-off waits for its final save. In a worker the
      # executor runs `resume_execution`, which takes it there.
      acquire_context_lock unless @context.inline_async_execution

      reset_held_lock_keys!
      acquire_locks_with_telemetry

      # Re-check the period gate now that we hold the lock. The pre-lock check
      # is a fast path; this one closes the race where two callers both passed
      # it and then serialized on the lock — without it the second caller would
      # re-run work the first already marked. (No-op when no lock is configured.)
      if (halted = check_period_gate)
        completed = true
        return finalize_halt(halted)
      end

      @context.admit!
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
    rescue Error::RollbackHandedOff => e
      record_rollback_handoff(e)
      completed = true
      @result
    rescue RubyReactor::Lock::AcquisitionError,
           RubyReactor::Semaphore::AcquisitionError,
           RubyReactor::RateLimit::ExceededError,
           RubyReactor::RateLimitRegistry::UnknownLimitError,
           RubyReactor::OrderedLock::WaitError => e
      @contention_snooze = true
      raise composed_contention_park(e) || e
    rescue Error::ExecutionParked
      # A park signal from a step of this run (its contention, or a wait on a
      # background result), reaching a composed child's or a map element's
      # first run. Every executor on the stack keeps its OWN lock/semaphore
      # through the gap and re-adopts it on redelivery (005 D-A2); the worker
      # at the top requeues once, after all of them have saved. A synchronous
      # caller never sees a park signal: nothing raises one outside a worker.
      park_held_primitives! if @context.inline_async_execution
      @contention_snooze = true
      raise
    rescue Error::Rescuable => e
      @result = handing_off { aborting_on_interruption { @result_handler.handle_execution_error(e) } }
      update_context_status(@result)
      completed = true
      @result
    rescue Exception # rubocop:disable Lint/RescueException
      mark_aborted
      raise
    ensure
      release_locks unless @parked
      leave_ordered_lock_scope
      save_context if persist_context? && !skip_context_persist?
      # Released only after that save (J-3, 009 R-13): a Worker waiting on the
      # lock then reads this run's final state.
      @acquired_context_lock&.release
      @acquired_context_lock = nil

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
      # A composed child re-entered while its own rollback is handed off.
      return resume_rollback if @context.rolling_back?

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
      # The only place a claimed resume payload enters a context (010 R-04,
      # J-5): under the run's lock, before the reactor-level lock or
      # semaphore, so a contended resume still saves the payload it applied.
      InterruptClaims.apply!(@context) if (@context.root_context || @context).equal?(@context)

      reset_held_lock_keys!

      # Resumes intentionally skip check_rate_limit (a paused run must not
      # block itself on resume), so acquire lock/semaphore directly rather
      # than via acquire_locks. A context parked on an async result kept its
      # primitives held across the gap — re-adopt them instead of re-competing.
      parked = consume_parked_primitives!
      if @reactor_class.respond_to?(:lock_config) && @reactor_class.lock_config
        acquire_exclusive_lock(reattach: parked[:lock])
      end
      if @reactor_class.respond_to?(:semaphore_config) && @reactor_class.semaphore_config
        acquire_semaphore(reattach_token: parked[:semaphore_token])
      end

      # Post-lock re-check (see execute) — closes the period race for the
      # first run of a locked async reactor.
      if first_run && (halted = check_period_gate)
        completed = true
        return finalize_halt(halted)
      end

      # Past every reactor-level gate. Idempotent for a genuine resume, which
      # was admitted on its first run (or, saved before `admitted` existed,
      # is marked now).
      @context.admit!
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
    rescue Error::RollbackHandedOff => e
      record_rollback_handoff(e)
      completed = true
      @result
    rescue RubyReactor::Lock::AcquisitionError,
           RubyReactor::Semaphore::AcquisitionError,
           RubyReactor::RateLimit::ExceededError,
           RubyReactor::RateLimitRegistry::UnknownLimitError,
           RubyReactor::OrderedLock::WaitError => e
      @contention_snooze = true
      raise composed_contention_park(e) || e
    rescue Error::ExecutionParked => e
      # A step of this run parked (contention, or an awaited background result
      # not terminal yet) — here, or in a composed child that already parked
      # its own holds on the way through. Exclusive lock and semaphore stay
      # HELD (recorded on the context for the resuming job to re-adopt); the
      # worker snoozes the job. The context lock is still released below — the
      # redelivered job must be able to take it.
      park_held_primitives!
      @contention_snooze = true
      raise e
    rescue Error::Rescuable => e
      handing_off { aborting_on_interruption { handle_resume_error(e) } }
      update_context_status(@result)
      completed = true
      @result
    rescue Exception # rubocop:disable Lint/RescueException
      mark_aborted
      raise
    ensure
      release_locks unless @parked
      # Saved while the context lock is still held (009 R-13): released first,
      # a worker resuming this run could load the pre-save blob, and this save
      # would then overwrite its progress.
      save_context unless skip_context_persist?
      @acquired_context_lock&.release
      @acquired_context_lock = nil
      leave_ordered_lock_scope

      emit_lifecycle_completion(completed)
    end

    # Undoes every completed step (manual undo, a composed child's undo, a
    # map element's rollback). A rollback that hands off here (009 R-04)
    # leaves this level's rollback failures on its context, and the next
    # `undo_all` of the same context picks them up, so none is lost though
    # the executor is rebuilt on resume (G2).
    def undo_all(&after_pop)
      saved = @context.rollback && @context.rollback["failures"]
      @compensation_manager.restore_rollback_failures(saved) if saved
      compensate_pending!
      @compensation_manager.rollback_completed_steps(&after_pop)
      clear_saved_rollback_failures
    rescue Error::RollbackHandedOff
      (@context.rollback ||= {})["failures"] =
        ContextSerializer.serialize_value(@compensation_manager.rollback_failures)
      raise
    end

    # Finishes a rollback that handed off at a fan-out map (009 R-04), once
    # the map's element rollbacks have all reported: the Worker of a
    # `rolling_back` run, or a composed child re-entered by its root. Under
    # the run's context lock, as `resume_execution`.
    def resume_rollback
      state = @context.rollback || {}
      # The hand-off came out of a running step (a composed child rolling
      # back inside `ComposeStep#run`): resume forward, and that step
      # finishes its child's rollback.
      if state["trigger"] == "step" || state.empty?
        @context.rollback = nil
        @context.status = :running
        return resume_execution
      end

      middlewares.on(:start_reactor, reactor_class.name, context.inputs, @context)
      completed = false
      enter_ordered_lock_scope
      acquire_context_lock
      @result = finish_rollback(state)
      @context.rollback = nil
      update_context_status(@result)
      completed = true
      @result
    rescue Error::RollbackHandedOff => e
      record_rollback_handoff(e)
      completed = true
      @result
    rescue RubyReactor::Lock::AcquisitionError => e
      @contention_snooze = true
      raise composed_contention_park(e) || e
    rescue Error::Rescuable => e
      handing_off { aborting_on_interruption { handle_resume_error(e) } }
      update_context_status(@result)
      completed = true
      @result
    rescue Exception # rubocop:disable Lint/RescueException
      mark_aborted
      raise
    ensure
      save_context unless skip_context_persist?
      @acquired_context_lock&.release
      @acquired_context_lock = nil
      leave_ordered_lock_scope

      emit_lifecycle_completion(completed)
    end

    # The rollback's other half (009 R-05): marks the hand-off saved, then
    # enqueues the owner's Worker if the map rollback already settled and this
    # side claims the signal. Whichever of this and the last element rollback
    # job sees both second enqueues the owner, once. Called right after the
    # `rolling_back` save, while the context lock is still held.
    def hand_off_rollback!(handed_off)
      storage = RubyReactor.configuration.storage_adapter
      map_id = handed_off.map_id
      map_class = handed_off.reactor_class_name
      storage.mark_map_rollback_handed_off(map_id, map_class)
      RubyReactor.configuration.logger.info(
        "event=ruby_reactor.rollback.handed_off context_id=#{@context.context_id.inspect} map_id=#{map_id.inspect}"
      )
      meta = storage.retrieve_map_rollback_metadata(map_id, map_class)
      return unless meta && storage.count_map_rollback_outcomes(map_id, map_class) >= meta["total"].to_i
      return unless storage.claim_map_rollback_signal(map_id, map_class)

      RubyReactor.configuration.async_router.perform_async(@context.context_id,
                                                           RubyReactor.reactor_storage_name(@reactor_class))
    end

    # Reached only by an interruption — a signal, an exit, out of memory, an
    # enclosing timeout (008 R-08, R-16); every other exception was rescued as
    # `Error::Rescuable` and rolled back. Running user rollback code now is
    # unsafe, so none runs: a run in the caller's process is recorded
    # `aborted`, with the undo entries not yet undone kept, for a manual
    # `Reactor#undo`; the `ensure` persists it, best effort. A worker run stays
    # `running` and its job is redelivered.
    def mark_aborted
      return if @context.inline_async_execution

      @context.status = :aborted
      # The failing step's `compensate`, if the interruption cut it off: a
      # manual undo runs it again before the undo stack (010 R-10, J-9).
      record = @compensation_manager.pending_record
      @context.rollback = record if record
    end

    # A rollback run from a `rescue Error::Rescuable` body is outside the
    # sibling `rescue Exception`, which never sees what that body raises: an
    # interruption there must mark the run here.
    def aborting_on_interruption
      yield
    rescue Exception => e # rubocop:disable Lint/RescueException
      mark_aborted unless Error::Rescuable === e || e.is_a?(Error::RollbackHandedOff) # rubocop:disable Style/CaseEquality
      raise
    end

    # A rollback run from a `rescue Error::Rescuable` body (the error's own
    # rollback) is outside the sibling `rescue Error::RollbackHandedOff`.
    def handing_off
      yield
    rescue Error::RollbackHandedOff => e
      record_rollback_handoff(e)
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

    # Wake any parent blocked in the notified wait on this execution. Published
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
    #
    # At most once per execution: a lock or semaphore contended right after
    # the charge snoozes the job BEFORE admission, and its redelivery is still
    # a first run. The `rate_limit_charged` marker rides `private_data`, so
    # that redelivery skips the charge but still runs every other first-run
    # gate (the period re-check above all).
    def check_rate_limit
      return unless @reactor_class.respond_to?(:rate_limit_config) && @reactor_class.rate_limit_config
      return if @context.private_data[:rate_limit_charged] || @context.private_data["rate_limit_charged"]

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
      @context.private_data[:rate_limit_charged] = true
    end

    # True when this execution has not yet passed its reactor-level gates —
    # the very first execution, including an async reactor's first worker
    # pass. Read from the explicit `admitted` marker, so a park at any depth
    # (which unwinds `with_step` and clears `current_step`) can never make a
    # redelivery look fresh and re-charge its rate limit (005 R-03). The old
    # inference is AND-ed in so a context saved before the marker existed
    # still resumes as it did.
    def first_execution?
      !@context.admitted? && @context.current_step.nil? && @context.intermediate_results.empty?
    end

    # A composed child's own reactor-level contention inside a worker. A
    # root's reaches `Worker#perform`, which snoozes the job; a child's would
    # first reach the step that composed it, which turns any error into an
    # ordinary step failure (F3). So the child raises a park signal instead,
    # and every executor above it keeps its holds until the worker requeues.
    #
    # Bounded where it is raised, like a step's contention park (005 R-05):
    # the child counts its own parks, and past `lock_snooze_max_attempts` the
    # contention error goes through as that step's failure, so the parent
    # rolls back and releases its holds — which the worker's snooze
    # escalation would do neither of. Returns nil to raise `error` unchanged.
    def composed_contention_park(error)
      return nil unless @context.inline_async_execution && @context.root_context
      # A configuration mistake, not contention: it stays a permanent failure.
      return nil if error.is_a?(RubyReactor::RateLimitRegistry::UnknownLimitError)
      return nil if within_inline_map_element?

      parks = (@context.private_data[:admission_parks] || @context.private_data["admission_parks"]).to_i + 1
      @context.private_data[:admission_parks] = parks
      max = RubyReactor.configuration.lock_snooze_max_attempts
      return nil if max != :infinity && parks > max

      Error::ReactorContentionPark.new(error)
    end

    # An inline (non-fan-out) map element has no persisted context of its own:
    # a park re-runs the whole map step with fresh element contexts, repeating
    # the elements that already finished and restarting the count above (005
    # R-01, "Known, not changed"). Under one, contention stays a failure.
    def within_inline_map_element?
      ctx = @context
      ctx = ctx.parent_context until ctx.nil? || (ctx.map_metadata && ctx.root_context)
      !ctx.nil?
    end

    # Record and persist a Halt result, then return it. Shared by the
    # pre-lock and post-lock period gates in both execute and resume.
    def finalize_halt(halted)
      @result = halted
      update_context_status(@result)
      save_context
      @result
    end

    # Returns a Halt result if the period bucket is already marked, else nil.
    # Consulted before AND after lock acquisition on a first execution; genuine
    # resumes never re-check (a paused run must not skip itself when its own
    # marker eventually appears).
    def check_period_gate
      return nil unless @reactor_class.respond_to?(:period_config) && @reactor_class.period_config

      config = @reactor_class.period_config
      key = period_key(config)
      return nil unless RubyReactor.configuration.storage_adapter.period_seen?(key)

      RubyReactor::Halt.new(reason: :period, period_key: key)
    end

    def mark_period_on_success(result)
      return unless @reactor_class.respond_to?(:period_config) && @reactor_class.period_config
      return unless result.is_a?(RubyReactor::Success)
      return if result.is_a?(RubyReactor::Halt)

      config = @reactor_class.period_config
      ttl = RubyReactor::Period.ttl_seconds(config[:every])
      RubyReactor.configuration.storage_adapter.period_mark(period_key(config), ttl, context_id: @context.context_id)
    end

    def period_key(config)
      base = config[:key_proc].call(@context.inputs)
      RubyReactor::Period.key(base, config[:every])
    end

    # One machine-parseable line whenever an execution reaches a terminal
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
    # Held by a worker's resume and by a run in the caller's process alike (010
    # R-01); an outer holder's owner, when set, is re-entered (R-03).
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

    def acquire_exclusive_lock(reattach: false)
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

      # Re-adopting a lock held across a parked gap: no :lock_acquired event —
      # the original acquisition already emitted it, and the eventual release
      # emits exactly one :lock_released. A lapsed TTL falls through to a
      # fresh acquire.
      if reattach && lock.reattach
        @acquired_lock = lock
        held_lock_keys << key
        return
      end

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

    def acquire_semaphore(reattach_token: nil)
      config = @reactor_class.semaphore_config
      key = config[:key_proc].call(@context.inputs)
      limit = config[:limit]

      semaphore = RubyReactor::Semaphore.new(key, limit: limit, wait: contention_wait(config[:wait]))

      # Same shape as the lock reattach above: keep the slot held across the
      # parked gap, no duplicate :semaphore_acquired event, fall through to a
      # fresh acquire when the token was lost in between.
      if reattach_token && semaphore.reattach(reattach_token)
        @acquired_semaphore = semaphore
        held_lock_keys << key if limit == 1
        return
      end

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

    # Park on a pending async result: keep exclusive lock / semaphore checked
    # out through the gap, recording just enough on the (about-to-be-saved)
    # context for the resuming job to re-adopt them. The lock's auto-extender
    # dies with this process, so the parked gap is bounded by the lock TTL —
    # the snooze redelivery (seconds) sits comfortably inside the default 60s.
    def park_held_primitives!
      @parked = true
      parked = {}

      if @acquired_lock
        @acquired_lock.detach
        parked[:lock] = true
        @acquired_lock = nil
      end

      if @acquired_semaphore
        parked[:semaphore_token] = @acquired_semaphore.token
        @acquired_semaphore = nil
      end

      @context.private_data[:parked_primitives] = parked if parked.any?
    end

    # One-shot: the marker is deleted on read so a crash after this point
    # degrades to a fresh acquire (reentrant by owner for the lock) rather
    # than a stale reattach on some later, unrelated resume.
    def consume_parked_primitives!
      raw = @context.private_data.delete(:parked_primitives) ||
            @context.private_data.delete("parked_primitives") || {}

      {
        lock: raw[:lock] || raw["lock"],
        semaphore_token: raw[:semaphore_token] || raw["semaphore_token"]
      }
    end

    def release_locks
      if @acquired_semaphore
        key = @acquired_semaphore.key
        release_one("semaphore", @acquired_semaphore)
        pop_held_lock_key(key)
        middlewares.on(:semaphore_released, key, @context)
      end
      @acquired_semaphore = nil

      return unless @acquired_lock

      key = @acquired_lock.key
      release_one("lock", @acquired_lock)
      pop_held_lock_key(key)
      @acquired_lock = nil
      middlewares.on(:lock_released, key, @context)
    end

    # Pop a SINGLE occurrence of `key`, not every occurrence (Finding 1).
    # With a reactor and a step both holding K, the step's release must not
    # erase the reactor's still-open entry — the async deadlock guard reads
    # this registry and would stop seeing K held while the reactor's own
    # hold is still live. `StepCoordination#pop_key` mirrors this exactly.
    def pop_held_lock_key(key)
      keys = held_lock_keys
      idx = keys.index(key)
      keys.delete_at(idx) if idx
    end

    # Exclusive keys this EXECUTION currently holds, recorded on the root
    # context so a dispatching step anywhere in the tree can see the whole
    # chain. Read by the async_reactor deadlock guard; nothing else
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
      when RubyReactor::DispatchResult
        # A rollback hand-off returns one too, and stays `rolling_back`.
        @context.status = :running unless @context.rolling_back?
      when RubyReactor::Halt
        @context.status = :halted
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
        # Halt must be listed before Success (Halt < Success) so the
        # halt path wins over the "continue with remaining steps" path.
        # Skipped is NOT listed here — it is a Success subclass and must
        # continue with the remaining steps, same as a plain Success.
        when RubyReactor::Halt,
             RetryQueuedResult,
             RubyReactor::Failure,
             RubyReactor::DispatchResult,
             RubyReactor::InterruptResult
          # Terminal: step halted, requeued, failed, paused, or handed
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

    # Where this level's rollback stands when it hands off (009 DM §1). A
    # composed child keeps it on its own context, inside the root's blob, and
    # re-raises; the top-level run saves it as `rolling_back` while it still
    # holds the context lock (I-6), runs the handshake, and returns a
    # `DispatchResult`, as a forward hand-off does.
    def record_rollback_handoff(handed_off)
      failure = handed_off.failure
      handed_off.failure = nil # this level's Failure; the level above builds its own
      @context.rollback = rollback_state(failure)
      @context.status = :rolling_back
      raise handed_off if @context.root_context

      save_context
      hand_off_rollback!(handed_off)
      @result = RubyReactor::DispatchResult.new(job_id: "map_rollback:#{handed_off.map_id}",
                                                intermediate_results: @context.intermediate_results,
                                                execution_id: @context.context_id)
    end

    # `trigger`: `failure` (a step failure is rolling back), `undo` (set by
    # `Reactor#undo`), or `step` (a running step's child handed off, and no
    # rollback started at this level). A later hand-off of the same rollback
    # keeps what an earlier one recorded.
    def rollback_state(failure)
      state = (@context.rollback || {}).dup
      pending = @compensation_manager.pending
      state["trigger"] ||= failure || pending ? "failure" : "step"
      if pending
        state["step"] = pending[:step].to_s
        state["compensated"] = pending[:compensated]
        state["compensation_error"] = pending[:compensation_error]
      end
      state["failure"] = ContextSerializer.serialize_value(failure) if failure
      state["failures"] = ContextSerializer.serialize_value(@compensation_manager.rollback_failures)
      state
    end

    # The rest of a handed-off rollback: the failing step's own compensate if
    # it had not finished (a map or compose adopts its settled state), the
    # steps still on the undo stack, then the outcome the inline rollback
    # gives (I-7).
    def finish_rollback(state)
      @compensation_manager.restore_rollback_failures(state["failures"])
      return finish_undo(state) if state["trigger"] == "undo"

      failure = ContextSerializer.deserialize_value(state["failure"])
      step_config = state["step"] && @reactor_class.steps[state["step"].to_sym]
      if step_config && !state["compensated"]
        @compensation_manager.handle_step_failure(step_config, failure.error, {})
      else
        @compensation_manager.rollback_completed_steps
        if state["compensation_error"]
          raise Error::CompensationError.new(state["compensation_error"], step: step_config&.name, context: @context)
        end
      end
      @context.current_step = failure.step_name&.to_sym
      @result_handler.handed_off_failure(failure)
    rescue Error::CompensationError => e
      @result_handler.handle_execution_error(e)
    end

    # A manual undo ends `cancelled`, or `failed` when it was the failure of
    # an interrupt whose payload attempts ran out (010 R-08).
    # An aborted run's failing step whose `compensate` an interruption cut off
    # (010 R-10, J-9): run it again, with the recorded arguments and reason,
    # before the undo stack. Only that record carries `arguments`; 009's
    # hand-off states, which name the same keys, are finished elsewhere.
    def compensate_pending!
      state = @context.rollback
      return unless state.is_a?(Hash) && state.key?("arguments") && state["compensated"] == false

      step_config = state["step"] && @reactor_class.steps[state["step"].to_sym]
      return unless step_config

      @compensation_manager.compensate(step_config, recorded_reason(state["error"]),
                                       ContextSerializer.deserialize_value(state["arguments"]))
      state["compensated"] = true
    end

    def recorded_reason(error)
      return error unless error.is_a?(Hash)

      Error::RecordedFailure.new(error["message"], original_class: error["class"])
    end

    def finish_undo(state)
      @compensation_manager.rollback_completed_steps
      if state["failure_reason"]
        @context.status = "failed"
        @context.failure_reason = state["failure_reason"]
        return nil
      end

      @context.cancelled = true
      @context.cancellation_reason = "Undo triggered"
      @context.status = "cancelled"
      nil
    end

    def clear_saved_rollback_failures
      return unless @context.rollback

      @context.rollback.delete("failures")
      @context.rollback = nil if @context.rollback.empty?
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
