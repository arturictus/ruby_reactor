# frozen_string_literal: true

module RubyReactor
  # rubocop:disable Metrics/ClassLength
  class Reactor
    include RubyReactor::Dsl::Reactor
    include RubyReactor::Dsl::Lockable

    # Seconds a manual undo waits for the run's context lock (009 R-12).
    UNDO_LOCK_WAIT = 5

    # Statuses a resume is accepted in: a run paused at an interrupt (008
    # FR-032), or one executing (another resume, its first run, a wait on
    # background work) for an interrupt that has not run yet (010 FR-017). A
    # finished, `aborted` or rolling-back run is never run forward.
    RESUMABLE_STATUSES = %w[paused running].freeze

    attr_reader :context, :result, :undo_trace, :execution_trace

    def self.find(id)
      reactor_class_name = name
      raw_data = configuration.storage_adapter.retrieve_context(id, reactor_class_name)
      raise Error::ValidationError, "Context '#{id}' not found" unless raw_data

      context = case raw_data
                when String
                  ContextSerializer.deserialize(raw_data)
                when Hash
                  Context.deserialize_from_retry(raw_data)
                else
                  raise Error::ValidationError, "Invalid context format for '#{id}'"
                end
      new(context)
    end

    def self.find_by_correlation_id(correlation_id)
      reactor_class_name = name
      context_id = configuration.storage_adapter.retrieve_context_id_by_correlation_id(
        correlation_id,
        reactor_class_name
      )
      raise Error::ValidationError, "Correlation ID '#{correlation_id}' not found" unless context_id

      find(context_id)
    end

    # How a resume names an interrupt: a Symbol for one of the reactor's own,
    # or its step path from the root (an Array: the compose step names, then
    # the interrupt) for one inside a composed child (010).
    def self.interrupt_key(step_name)
      path = Array(step_name).map(&:to_sym)
      path.one? ? path.first : path
    end

    def self.continue(id:, payload:, step_name:, idempotency_key: nil)
      reactor = find(id)
      result = reactor.continue(payload: payload, step_name: step_name, idempotency_key: idempotency_key)

      if result.is_a?(RubyReactor::Failure) && result.respond_to?(:invalid_payload?) && result.invalid_payload?
        # Raise exception to match expected behavior (strict mode for class method)
        # We do NOT cancel the reactor, allowing the user to retry with valid payload
        raise Error::InputValidationError, result.error
      end

      result
    end

    def self.continue_by_correlation_id(correlation_id:, payload:, step_name:, idempotency_key: nil)
      reactor = find_by_correlation_id(correlation_id)
      # We delegate to the class-level continue method to ensure auto-compensation logic applies
      # by using the context ID found by find_by_correlation_id
      continue(id: reactor.context.context_id, payload: payload, step_name: step_name, idempotency_key: idempotency_key)
    end

    def self.cancel(id:, reason:)
      reactor = find(id)
      reactor.cancel(reason)
    end

    # A rollback that hands off at a fan-out map finishes in a worker, which
    # applies `cancelled` itself (009 R-12).
    def self.undo(id)
      reactor = find(id)
      return if reactor.undo == :handed_off

      cancel(id: id, reason: "Undo triggered")
    end

    def self.configuration
      RubyReactor::Configuration.instance
    end

    def initialize(context = {})
      @context = context
      @result = :unexecuted

      if @context.is_a?(Context)
        @execution_trace = @context.execution_trace || []
        @undo_trace = @execution_trace.select { |e| e[:type] == :undo }
        @result = reconstruct_result
      else
        @undo_trace = []
        @execution_trace = []
      end
    end

    def run(inputs = {})
      # Before the context exists, so an incomplete definition never saves one.
      self.class.validate_definition!

      # For all reactors, initialize context first to capture execution ID
      @context = @context.is_a?(Context) ? @context : Context.new(inputs, self.class)

      # Validate inputs
      validation_result = self.class.validate_inputs(inputs)
      if validation_result.failure?
        handle_validation_failure(validation_result)
        return validation_result
      end

      # Assign-at-enqueue: ordered_lock nonce is INCRed atomically here so
      # the order matches the caller's order, not whichever worker happens to
      # pick the job up first.
      assign_ordered_lock_nonce!

      if self.class.async? && !@context.inline_async_execution
        # For async reactors, queue a job for the whole reactor
        @context.status = :running
        Executor.middlewares_for(self.class).on(:before_async_enqueue, @context)
        # Persist BEFORE enqueue — the job payload is identity-only (F2).
        save_context

        @result = configuration.async_router.perform_async(@context.context_id,
                                                           RubyReactor.reactor_storage_name(self.class),
                                                           intermediate_results: @context.intermediate_results)

        # Even if it's an DispatchResult, it might have finished inline (e.g. Sidekiq::Testing.inline!)
        # Check storage to see if it's already finished or paused (interrupted).
        begin
          reloaded = self.class.find(@context.context_id)
          if reloaded.finished? || reloaded.context.status.to_s == "paused"
            @context = reloaded.context
            @result = reloaded.result
            @execution_trace = reloaded.execution_trace
            @undo_trace = reloaded.undo_trace
            return @result
          end
        rescue StandardError
          # Ignore if not found or other errors during reload check
        end

      else
        # For sync reactors (potentially with async steps), execute normally
        context = @context.is_a?(Context) ? @context : nil
        executor = Executor.new(self.class, inputs, context)
        @result = executor.execute
        @context = executor.context
        @execution_trace = executor.execution_trace
        @undo_trace = executor.undo_trace
      end
      @result
    end

    # Accepting a resume (010 R-05, contracts/resume-protocol.md P-2–P-4):
    #
    # 1. checks on the loaded snapshot, then the payload is validated here, in
    #    the caller's process. An invalid payload stores and enqueues nothing;
    # 2. the interrupt is claimed (`SET NX`): one resume per interrupt, in every
    #    execution mode. The claim holds the payload;
    # 3. if the run's lock is free, this process owns the run: it reloads it and
    #    resumes inline, as before. Otherwise (another execution is live, the
    #    reactor's lock or semaphore is held, or a background-resume interrupt)
    #    the resume is handed to a Worker, which applies the claim under the
    #    run's lock, and a `DispatchResult` comes back.
    #
    # The payload is never validated again (J-7), so an accepted resume cannot
    # fail validation later.
    def continue(payload:, step_name:, idempotency_key: nil)
      _ = idempotency_key

      path = Array(self.class.interrupt_key(step_name))
      _, step_config = ensure_resumable!(path)

      # A claimed resume is accepted: a later payload, valid or not, must not
      # count against `max_attempts` and undo the run it is about to complete.
      raise_already_resumed(path) if InterruptClaims.claimed?(@context, path)

      failure = validate_continue_payload(payload, step_config, path)
      return failure if failure

      raise_already_resumed(path) unless InterruptClaims.claim!(@context, path, payload)

      resume_claimed(path, step_config, payload)
    rescue Error::InputValidationError => e
      # This might catch other validations, but here we specifically want payload validation.
      # The block above handles payload validation explicitly.
      RubyReactor::Failure(e.message, invalid_payload: true)
    end

    # Undoes every completed step, under the run's context lock so no worker
    # resumes it meanwhile (009 R-12). Returns `:handed_off` when a fan-out
    # map's rollback continues in its element jobs: the run is then
    # `rolling_back`, and a worker finishes it as `cancelled`.
    #
    # Lock, then load (010 R-09): the run is reloaded once the lock is held, so
    # an undo built from an older snapshot never undoes stale state. With
    # `failure:` the run ends `failed` with that reason (an interrupt's payload
    # attempts ran out, R-08) instead of being left for `cancel`.
    def undo(failure: nil)
      raise Error::ValidationError, "rollback already in progress" if @context.rolling_back?

      lock = acquire_undo_lock
      @context = self.class.find(@context.context_id).context
      raise Error::ValidationError, "rollback already in progress" if @context.rolling_back?

      executor = Executor.new(self.class, {}, @context)
      # An aborted run may record a `compensate` the interruption cut off:
      # keep it, so `undo_all` runs it first (010 R-10).
      cut_off = if @context.status.to_s == "aborted" && @context.rollback.is_a?(Hash) &&
                   @context.rollback.key?("arguments")
                  @context.rollback
                else
                  {}
                end
      @context.rollback = { "trigger" => "undo", "compensated" => true, "failures" => [] }
                          .merge(cut_off.slice("step", "compensated", "arguments", "error"))
      # A hand-off finishes in a worker (`Executor#finish_undo`), which applies it.
      @context.rollback["failure_reason"] = failure if failure
      begin
        executor.undo_all
      rescue Error::RollbackHandedOff => e
        @context.status = :rolling_back
        executor.save_context
        executor.hand_off_rollback!(e)
        return :handed_off
      end
      @context.rollback = nil
      if failure
        @context.status = "failed"
        @context.failure_reason = failure
      end
      executor.save_context
    ensure
      lock&.release
    end

    def cancel(reason)
      # `cancelled` is terminal: the steps before the map would never be undone.
      raise Error::ValidationError, "rollback in progress; cannot cancel" if @context.rolling_back?

      @context.cancelled = true
      @context.cancellation_reason = reason
      @context.status = "cancelled"
      save_context
    end

    # The interrupts this paused run can be resumed at (010 R-05): a Symbol
    # for one of this reactor's own, and the step path from here (the compose
    # step names, then the interrupt) for one inside a composed child.
    def ready_interrupt_steps
      return [] unless RESUMABLE_STATUSES.include?(@context.status.to_s)

      pending_interrupts(self.class, @context, [])
    end

    def validate!
      # Validate reactor configuration
      validate_steps!
      validate_return_step!
      validate_dependencies!
    end

    private

    def configuration
      RubyReactor::Configuration.instance
    end

    # Returns the context that paused at the interrupt `path` and its config.
    def ensure_resumable!(path)
      if @context.status.to_s == "paused" && !@context.current_step
        raise Error::ValidationError, "Cannot resume: context does not have a current step (was it interrupted?)"
      end

      # A composed child pauses only inside its root, which owns the run (010 R-07).
      if @context.private_data[:composed] || @context.private_data["composed"]
        raise Error::ValidationError, "Cannot resume: #{self.class.name} is a composed child; continue its root run"
      end

      if @context.cancelled
        raise Error::ValidationError,
              "Cannot resume: reactor has been cancelled (Reason: #{@context.cancellation_reason})"
      end

      unless RESUMABLE_STATUSES.include?(@context.status.to_s)
        raise Error::ValidationError,
              "Cannot resume: the reactor is #{@context.status}, not paused or running at an interrupt"
      end

      target_context, step_config = resolve_interrupt_target!(path)
      raise_already_resumed(path) if target_context.has_result?(path.last)

      [target_context, step_config]
    end

    def raise_already_resumed(path)
      raise Error::ValidationError, "Cannot resume: interrupt :#{path.join(".")} was already resumed"
    end

    # Owns a paused run if its lock is free (lock, then load), else hands off.
    # A running run is another execution's: the resume joins it through a
    # Worker and never runs it here. The lock is released before any hand-off
    # enqueues, so the Worker never waits on it; a crash in between leaves a
    # `running` run the sweeper recovers.
    def resume_claimed(path, step_config, payload)
      lock = @context.status.to_s == "paused" ? try_run_lock : :contended
      return hand_off_resume(path, reason: :run_busy) if lock == :contended

      begin
        reload_for_resume!
        # This process owns the run: apply the caller's payload as given, as
        # an inline resume always did (the claim's copy went through
        # serialization). Other claims are applied from storage at resume.
        if @context.status.to_s == "paused"
          path[0...-1].reduce(@context) { |context, name| paused_child(context, name) }
                      &.set_result(path.last, payload)
        end
        if @context.status.to_s != "paused"
          reason = :run_busy
        elsif background_resume?(step_config)
          prepare_background_resume
          reason = :background
        else
          return resume_inline(lock)
        end
      rescue Lock::AcquisitionError, Semaphore::AcquisitionError => e
        # The run's own lock is held here, so this is the reactor's `with_lock`
        # or `with_semaphore`: the resume, already saved `running` with its
        # payload applied, waits in a worker instead (FR-009).
        raise if e.is_a?(Lock::ContextLockContention)

        reason = e.is_a?(Semaphore::AcquisitionError) ? :semaphore : :lock
      ensure
        lock&.release
      end
      hand_off_resume(path, reason: reason, key: contended_key(reason))
    end

    # nil in inline job-testing mode (no run lock there, as in the executor);
    # :contended while another execution holds it.
    def try_run_lock
      return nil if inline_testing_mode?

      lock = RubyReactor::Lock.new("async:#{@context.context_id}", owner: SecureRandom.uuid,
                                                                   ttl: configuration.context_lock_ttl,
                                                                   wait: 0, auto_extend: true)
      lock.acquire
      lock
    rescue Lock::AcquisitionError
      :contended
    end

    def reload_for_resume!
      @context = self.class.find(@context.context_id).context
      return unless @context.cancelled || @context.finished? || @context.rolling_back? ||
                    @context.status.to_s == "aborted"

      raise Error::ValidationError,
            "Cannot resume: the reactor is #{@context.status}, not paused at an interrupt"
    end

    def resume_inline(lock)
      executor = Executor.new(self.class, {}, @context)
      executor.context_lock_owner = lock&.owner
      @result = executor.resume_execution
      @context = executor.context
      @undo_trace = executor.undo_trace
      @execution_trace = executor.execution_trace
      @result
    end

    def background_resume?(step_config)
      step_config.respond_to?(:background_resume?) && step_config.background_resume?
    end

    # `interrupt :x, resume: :background`: the payload is applied and the run
    # saved `running` under its lock; the remaining work goes to a worker.
    def prepare_background_resume
      InterruptClaims.apply!(@context)
      @context.status = :running
      Executor.middlewares_for(self.class).on(:before_async_enqueue, @context)
      save_context
    end

    def hand_off_resume(path, reason:, key: nil)
      log_resume_deferred(path, reason, key)
      @result = configuration.async_router.perform_async(@context.context_id,
                                                         RubyReactor.reactor_storage_name(self.class),
                                                         intermediate_results: @context.intermediate_results)
      check_for_inline_completion || @result
    end

    def log_resume_deferred(path, reason, key)
      fields = { event: "ruby_reactor.resume.deferred", reactor: RubyReactor.reactor_storage_name(self.class),
                 context_id: @context.context_id, step: path.join("."), reason: reason.to_s, key: key }
      configuration.logger.info(fields.map { |k, v| "#{k}=#{v.inspect}" }.join(" "))
    end

    def contended_key(reason)
      config = case reason
               when :lock then self.class.respond_to?(:lock_config) && self.class.lock_config
               when :semaphore then self.class.respond_to?(:semaphore_config) && self.class.semaphore_config
               end
      config ? config[:key_proc].call(@context.inputs).to_s : nil
    rescue StandardError
      nil
    end

    def inline_testing_mode?
      defined?(Sidekiq::Testing) && Sidekiq::Testing.respond_to?(:inline?) && Sidekiq::Testing.inline?
    end

    # Raises `Lock::AcquisitionError` while a live run or rollback holds it.
    # Skipped in inline job-testing mode, as `Executor#acquire_context_lock`.
    def acquire_undo_lock
      return if inline_testing_mode?

      lock = RubyReactor::Lock.new("async:#{@context.context_id}", owner: SecureRandom.uuid,
                                                                   ttl: configuration.context_lock_ttl,
                                                                   wait: UNDO_LOCK_WAIT)
      lock.acquire
      lock
    end

    def validate_steps!
      return unless self.class.steps.empty?

      raise Error::ValidationError, "Reactor must have at least one step"
    end

    def validate_return_step!
      return unless self.class.return_step

      return if self.class.steps.key?(self.class.return_step)

      raise Error::ValidationError, "Return step '#{self.class.return_step}' is not defined"
    end

    def validate_dependencies!
      graph = DependencyGraph.new
      self.class.steps.each_value { |config| graph.add_step(config) }

      return unless graph.has_cycles?

      raise Error::DependencyError, "Dependency graph contains cycles"
    end

    def reconstruct_result
      case @context.status.to_s
      when "completed" then reconstruct_success_result
      when "failed" then reconstruct_failure_result
      when "paused" then reconstruct_paused_result
      else :unexecuted
      end
    end

    def reconstruct_success_result
      rs = self.class.respond_to?(:returns) ? self.class.returns : nil
      val = if rs
              @context.intermediate_results[rs.to_sym] || @context.intermediate_results[rs.to_s]
            else
              find_last_step_result
            end
      Success.new(val)
    end

    def find_last_step_result
      last_run = @execution_trace.reverse.find { |e| e[:type] == :run || e["type"] == "run" }
      return unless last_run

      step_name = last_run[:step] || last_run["step"]
      @context.intermediate_results[step_name.to_sym] || @context.intermediate_results[step_name.to_s]
    end

    def reconstruct_failure_result
      reason = @context.failure_reason || {}
      return reason if reason.is_a?(RubyReactor::Failure)

      # Presence-aware: a stored `retryable: false` must not be swallowed by an
      # `||` fallback and silently default back to retryable.
      r = ->(k) { Utils::FetchIndifferent.call(reason, k) }

      Failure.new(
        r[:message],
        step_name: r[:step_name],
        inputs: r[:inputs] || {},
        backtrace: r[:backtrace],
        reactor_name: r[:reactor_name],
        step_arguments: r[:step_arguments] || {},
        exception_class: r[:exception_class],
        file_path: r[:file_path],
        line_number: r[:line_number],
        code_snippet: r[:code_snippet],
        validation_errors: r[:validation_errors],
        retryable: r[:retryable],
        invalid_payload: r[:invalid_payload]
      )
    end

    def reconstruct_paused_result
      InterruptResult.new(
        execution_id: @context.context_id,
        intermediate_results: @context.intermediate_results
      )
    end

    def initialize_and_validate_run?(inputs)
      # For all reactors, initialize context first to capture execution ID
      @context = @context.is_a?(Context) ? @context : Context.new(inputs, self.class)

      validation_result = self.class.validate_inputs(inputs)
      if validation_result.failure?
        handle_validation_failure(validation_result)
        return false
      end
      true
    end

    def handle_validation_failure(result)
      @result = result
      @context.status = "failed"
      @context.failure_reason = {
        message: result.error.message,
        validation_errors: result.error.field_errors,
        retryable: result.retryable?
      }
      save_context
    end

    def perform_async_run
      @context.status = :running
      # Persist BEFORE enqueue — the job payload is identity-only (F2).
      save_context

      @result = configuration.async_router.perform_async(@context.context_id,
                                                         RubyReactor.reactor_storage_name(self.class),
                                                         intermediate_results: @context.intermediate_results)

      check_for_inline_completion
    end

    def check_for_inline_completion
      # Even if it's an DispatchResult, it might have finished inline (e.g. Sidekiq::Testing.inline!)
      # Check storage to see if it's already finished or paused (interrupted).
      reloaded = self.class.find(@context.context_id)
      if reloaded.finished? || reloaded.context.status.to_s == "paused"
        update_state_from_reloaded(reloaded)
        @result
      end
    rescue StandardError
      # Ignore if not found or other errors during reload check
    end

    def update_state_from_reloaded(reloaded)
      @context = reloaded.context
      @result = reloaded.result
      @execution_trace = reloaded.execution_trace
      @undo_trace = reloaded.undo_trace
    end

    def perform_sync_run(inputs)
      context = @context.is_a?(Context) ? @context : nil
      executor = Executor.new(self.class, inputs, context)
      @result = executor.execute
      @context = executor.context
      @execution_trace = executor.execution_trace
      @undo_trace = executor.undo_trace
    end

    # The context that paused at the interrupt `path` names, and that
    # interrupt's config. A one-name path is a step of this reactor; a longer
    # one names compose steps from here down, then the interrupt (010 R-05).
    def resolve_interrupt_target!(path)
      pending = ready_interrupt_steps
      key = path.one? ? path.first : path
      unless pending.include?(key)
        raise Error::ValidationError,
              "Cannot resume: expected step '#{@context.current_step}' " \
              "or ready steps #{pending.inspect} but got '#{key}'"
      end

      target = path[0...-1].reduce(@context) { |context, name| paused_child(context, name) }
      [target, target.reactor_class.steps[path.last]]
    end

    def pending_interrupts(reactor_class, context, prefix)
      graph_manager = Executor::GraphManager.new(reactor_class, DependencyGraph.new, context)
      graph_manager.build_and_validate!
      graph_manager.mark_completed_steps_from_context

      # The interrupt a context paused at stays pending even once a resume
      # stored its payload: that resume was contended and never ran.
      ready = graph_manager.dependency_graph.ready_steps
      paused_at = reactor_class.steps[context.current_step&.to_sym]
      ready += [paused_at] if paused_at&.interrupt? && ready.none? { |step| step.name == paused_at.name }

      ready.flat_map do |step_config|
        name = step_config.name.to_sym
        if step_config.respond_to?(:interrupt?) && step_config.interrupt?
          [prefix.empty? ? name : prefix + [name]]
        elsif (child = paused_child(context, name))
          pending_interrupts(child.reactor_class, child, prefix + [name])
        else
          []
        end
      end
    end

    def paused_child(context, step_name)
      entry = context.composed_contexts[step_name] || context.composed_contexts[step_name.to_s]
      child = entry.is_a?(Hash) && (entry[:context] || entry["context"])
      child if child.is_a?(Context) && child.status.to_s == "paused"
    end

    def validate_continue_payload(payload, step_config, path)
      return unless step_config&.validation_schema

      # A nested interrupt counts apart from a root step of the same name.
      step_name = path.one? ? path.first : path.join(".").to_sym

      validation = step_config.validation_schema.call(payload)

      return unless validation.failure?

      # Counted in its own record (010 R-08): writing the snapshot here could
      # overwrite a resume that is executing the run right now.
      current_attempts = configuration.storage_adapter.increment_interrupt_attempts(
        @context.context_id, RubyReactor.reactor_storage_name(self.class), step_name
      )
      max_attempts = step_config.max_attempts

      if max_attempts != :infinity && current_attempts >= max_attempts
        # Max attempts reached: undo, and mark the run failed (not cancelled)
        # so it shows up as failed in the UI. Both under the run's lock (R-09).
        undo(failure: {
               message: "Validation failed after #{max_attempts} attempts",
               step_name: step_name,
               errors: validation.errors.to_h,
               payload: payload,
               step_arguments: payload,
               attempts: current_attempts,
               validation_errors: validation.errors.to_h
             })

        return RubyReactor::Failure(
          "Validation failed after #{max_attempts} attempts",
          step_name: step_name,
          step_arguments: payload,
          validation_errors: validation.errors.to_h
        )
      end

      failure = RubyReactor::Failure(validation.errors.to_h)
      # We need a way to mark this failure as a validation failure
      # For now, we rely on the error object inside Failure or just return Failure
      # The PRD requires `result.invalid_payload?` to be true.
      # Since we don't have that method on Failure yet, we might need to enhance Failure
      # OR wrap it. For now, let's assume Failure wraps the error and we can check it.
      # We'll use a specific error type to identify it.
      failure.instance_variable_set(:@type, :input_validation)
      def failure.invalid_payload? = true
      failure
    end

    def save_context
      storage = configuration.storage_adapter
      reactor_class_name = RubyReactor.reactor_storage_name(self.class)
      serialized_context = ContextSerializer.serialize(@context)
      storage.store_context(@context.context_id, serialized_context, reactor_class_name)
    end

    def assign_ordered_lock_nonce!
      return unless self.class.respond_to?(:ordered_lock_config) && self.class.ordered_lock_config
      return if @context.private_data[:ordered_lock] || @context.private_data["ordered_lock"]

      config = self.class.ordered_lock_config
      key = config[:key_proc].call(@context.inputs)

      # Synchronous nested `Reactor.run` of an ordered-lock reactor on the same
      # key would deadlock: the outer nonce holds the slot, an inner nonce
      # would never advance until the outer completes — but the outer is
      # blocked waiting for the inner to return. Mirror the compose behavior:
      # silently skip nonce assignment (the inner runs without gate/advance)
      # and log a warning so this isn't invisible.
      active = Executor::OrderedLockSupport.active_keys
      if active.include?(key)
        RubyReactor.configuration.logger.warn(
          "RubyReactor: nested `Reactor.run` of #{self.class.name || "<anonymous>"} on " \
          "ordered-lock key '#{key}' from inside another ordered-lock reactor on the same " \
          "key — nonce assignment skipped, inner run executes without ordering enforcement. " \
          "Use a different key or move the inner call to a top-level invocation if you need ordering."
        )
        return
      end

      nonce, epoch = RubyReactor::OrderedLock.assign(key, ttl: config[:ttl])

      @context.private_data[:ordered_lock] = {
        key: key,
        nonce: nonce,
        epoch: epoch,
        poison_pill_timeout: config[:poison_pill_timeout],
        ttl: config[:ttl],
        strict: config.fetch(:strict, true)
      }
    end
  end
  # rubocop:enable Metrics/ClassLength
end
