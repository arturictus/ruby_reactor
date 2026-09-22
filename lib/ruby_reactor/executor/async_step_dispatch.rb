# frozen_string_literal: true

module RubyReactor
  class Executor
    # The dispatching half of `async_step`, mixed into StepExecutor. Split out
    # because it is a self-contained concern — write the durable record and the
    # context reference, enqueue, then mark the node graph-complete — and because
    # it is where the structured logging for every hand-off lives.
    module AsyncStepDispatch
      private

      # Send one step's work off as its own job and KEEP GOING.
      #
      # The ordering below is load-bearing (F2): the durable record and the
      # context reference are written BEFORE the enqueue, so a crash in between
      # can never leave a job with no record — and that same record is what
      # tells a recovery pass the work is already out there, so it
      # re-attaches instead of dispatching a duplicate side effect.
      #
      # Deliberately NOT gated on `inline_async_execution`: that flag stops the
      # `background` hand-off from re-triggering inside a worker, but an
      # `async_step` reached during a worker resume must still get its own job,
      # or the feature silently degrades to inline execution exactly where the
      # spec says it must not.
      def dispatch_async_step(step_config)
        if already_dispatched?(step_config)
          @dependency_graph.complete_step(step_config.name)
          return RubyReactor.Success(nil)
        end

        deadlock = check_async_step_deadlock(step_config)
        return deadlock if deadlock

        record_async_step_dispatch(step_config)
        enqueue_async_step(step_config)

        # Mark complete for SCHEDULING only — no result is recorded, so
        # `result(:name)` still routes through the notified wait. This is what
        # lets unrelated siblings become ready and run while the unit is in
        # flight, instead of the loop returning early on an DispatchResult.
        @dependency_graph.complete_step(step_config.name)
        RubyReactor.Success(nil)
      end

      def already_dispatched?(step_config)
        !storage.retrieve_step_result(@context.context_id, step_config.name, async_step_class_name).nil?
      end

      # US4/T034: an `async_step` whose step class declares a key this
      # execution currently holds would deadlock exactly like `async_reactor`
      # dispatching into one — refuse before the durable record is written or
      # the job is enqueued, naming the key (Step::AsyncReactorStep's guard
      # already covers `async_reactor`; this reuses its message and registry).
      def check_async_step_deadlock(step_config)
        held = Step::AsyncReactorStep.held_lock_keys(@context)
        return nil if held.empty?

        # Only lock and a limit-1 semaphore have the circular-wait shape this
        # guard defends against (same registry `with_lock`/limit-1
        # `with_semaphore` push to, T032). Rate limit, period, and the
        # ordered lock never enter `held_lock_keys`, so they cannot deadlock
        # a hand-off and are deliberately not checked here.
        lock_config = step_config.lock_config
        semaphore_config = step_config.semaphore_config
        return nil unless lock_config || (semaphore_config && semaphore_config[:limit] == 1)

        args = resolve_args_for_deadlock_check(step_config)
        return args if args.is_a?(RubyReactor::Failure) # KeyError or "skip, can't resolve without blocking"
        return nil if args.nil? # skipped — non-blocking resolution was not possible

        collision = async_step_lock_keys(lock_config, semaphore_config, args).find { |key| held.include?(key) }
        return nil unless collision

        RubyReactor.Failure(
          Step::AsyncReactorStep.deadlock_message(collision, "#{@reactor_class&.name}##{step_config.name}",
                                                  @context, kind: "async_step")
        )
      end

      def async_step_lock_keys(lock_config, semaphore_config, args)
        keys = []
        keys << lock_config[:key_proc].call(args) if lock_config
        keys << semaphore_config[:key_proc].call(args) if semaphore_config && semaphore_config[:limit] == 1
        keys.compact
      end

      # Finding 5: `async_step` defers argument resolution to the worker, so
      # computing the key here means resolving early — safe UNLESS an
      # argument reads a still-pending async result, which would BLOCK (or
      # park) this dispatching step just to run a guard check. Detect that
      # case without calling `.resolve` at all, skip the guard, and log it.
      def resolve_args_for_deadlock_check(step_config)
        if step_config.arguments.values.any? { |cfg| pending_async_source?(cfg[:source]) }
          log_guard_skipped(step_config)
          return nil
        end

        resolved = {}
        step_config.arguments.each do |name, cfg|
          value = cfg[:source].resolve(@context)
          value = cfg[:transform].call(value) if cfg[:transform]
          resolved[name] = value
        end
        resolved
      rescue Executor::StepCoordination::KeyError => e
        RubyReactor::Failure(e, step_name: step_config.name, reactor_name: @reactor_class&.name, retryable: false)
      end

      def pending_async_source?(source)
        return false unless source.is_a?(RubyReactor::Template::Result)
        return false if @context.intermediate_results.key?(source.step_name.to_sym) ||
                        @context.intermediate_results.key?(source.step_name.to_s)

        ref = @context.composed_contexts[source.step_name] || @context.composed_contexts[source.step_name.to_s]
        ref.is_a?(Hash) && %i[async_step_ref async_reactor_ref].include?(ref[:type]&.to_sym)
      end

      def log_guard_skipped(step_config)
        configuration.logger.info(
          "event=\"ruby_reactor.step_coordination.guard_skipped\" reactor=#{@reactor_class&.name.inspect} " \
          "step=#{step_config.name.inspect} execution_id=#{@context.context_id.inspect}"
        )
      end

      def record_async_step_dispatch(step_config)
        root = @context.root_context || @context
        @context.composed_contexts[step_config.name] = {
          name: step_config.name,
          type: :async_step_ref,
          # Carried on the ref so the dashboard can find the Step Result Record
          # from the reference alone, without re-deriving which context owns it.
          context_id: @context.context_id,
          dispatched_at: Time.now
        }
        storage.store_step_result(
          @context.context_id, step_config.name,
          {
            "status" => "dispatched", "dispatched_at" => Time.now.iso8601,
            # The re-dispatch arguments, verbatim. The record's own key names the
            # reactor that OWNS the step, which for a composed child is not the
            # root the worker must load, so recovery cannot re-derive them.
            "root_context_id" => root.context_id,
            "reactor_class_name" => RubyReactor.reactor_storage_name(root.reactor_class),
            "step_context_id" => @context.context_id,
            "step_name" => step_config.name.to_s
          },
          async_step_class_name
        )

        # The worker loads the parent by id, so the parent must be durable
        # before the job exists AND must outlive the dispatched unit — including
        # the fire-and-forget case where this reactor finishes immediately and
        # nothing ever waits.
        checkpoint_root!(root, RubyReactor.reactor_storage_name(root.reactor_class))
      end

      def enqueue_async_step(step_config)
        root = @context.root_context || @context
        log_async_event("async_step.dispatched", step_config.name)
        configuration.async_router.perform_step_async(
          root_context_id: root.context_id,
          reactor_class_name: RubyReactor.reactor_storage_name(root.reactor_class),
          step_context_id: @context.context_id,
          step_name: step_config.name
        )
      end

      # Step Result Records are namespaced by the reactor that OWNS the step,
      # which for a composed child is the child — the same name the reader's
      # `Template::Result` will look under.
      def async_step_class_name
        RubyReactor.reactor_storage_name(@context.reactor_class || @reactor_class)
      end

      def storage
        RubyReactor::Configuration.instance.storage_adapter
      end

      # One machine-parseable line per hand-off / dispatch, carrying the
      # three identifiers needed to correlate it with everything else, plus
      # any extra key=value fields (e.g. a park's key/primitive/attempt),
      # inserted before execution_id so it always trails the line.
      def log_async_event(event, step_name, **fields)
        extra = fields.map { |k, v| " #{k}=#{v.inspect}" }.join
        configuration.logger.info(
          "event=\"ruby_reactor.#{event}\" reactor=#{@reactor_class&.name.inspect} " \
          "step=#{step_name.inspect}#{extra} execution_id=#{@context.context_id.inspect}"
        )
      end
    end
  end
end
