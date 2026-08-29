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

      def record_async_step_dispatch(step_config)
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
          { "status" => "dispatched", "dispatched_at" => Time.now.iso8601 },
          async_step_class_name
        )

        # The worker loads the parent by id, so the parent must be durable
        # before the job exists AND must outlive the dispatched unit — including
        # the fire-and-forget case where this reactor finishes immediately and
        # nothing ever waits.
        root = @context.root_context || @context
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
      # three identifiers needed to correlate it with everything else.
      def log_async_event(event, step_name)
        configuration.logger.info(
          "event=\"ruby_reactor.#{event}\" reactor=#{@reactor_class&.name.inspect} " \
          "step=#{step_name.inspect} execution_id=#{@context.context_id.inspect}"
        )
      end
    end
  end
end
