# frozen_string_literal: true

module RubyReactor
  module Step
    # The dispatching half of `async_reactor`: everything that happens in the
    # PARENT's process. The child then runs as an ordinary independently
    # dispatched reactor execution — no new enqueue primitive, no new storage
    # primitive, and no entry in the parent's compensation graph.
    #
    # Dispatch reuses the full pre-enqueue sequence of a top-level async run
    # (FR-016) rather than a raw `perform_async`, because `Reactor#run` does
    # three load-bearing things a naive `Context.new` + enqueue would silently
    # skip: validate the child's inputs (the worker's resume path never
    # validates, so skipping here starts a child on garbage), assign the
    # ordered-lock nonce at ENQUEUE time (so ordering matches caller order), and
    # persist before enqueueing (F2).
    class AsyncReactorStep
      include RubyReactor::Step

      class << self
        def run(arguments, context)
          child_class = arguments[:async_reactor_class]
          child_inputs = build_child_inputs(arguments[:argument_mappings] || {}, context)

          # A dispatch-time failure fails the DISPATCHING step, i.e. normal saga
          # handling in the parent. That is deliberately outside FR-009's
          # no-auto-compensation rule, which governs the child's own execution.
          validation = validate_child_inputs(child_class, child_inputs)
          return validation if validation

          deadlock = detect_lock_deadlock(child_class, child_inputs, context)
          return deadlock if deadlock

          return run_inline(child_class, child_inputs, context) if run_inline?(context)

          dispatch(child_class, child_inputs, context)
        end

        private

        def build_child_inputs(mappings, context)
          mappings.transform_values { |source| source.resolve(context) }
        end

        def validate_child_inputs(child_class, child_inputs)
          return nil unless child_class.respond_to?(:validate_inputs)

          result = child_class.validate_inputs(child_inputs)
          return nil unless result.failure?

          RubyReactor.Failure(
            "async_reactor child #{child_class.name} rejected its inputs: #{result.error.message}",
            validation_errors: (result.error.field_errors if result.error.respond_to?(:field_errors))
          )
        end

        # FR-015. Lock ownership is NOT shared across the async boundary: parent
        # and child run concurrently, so giving the child the parent's owner
        # would put both inside the critical section at once — mutual exclusion
        # silently broken, which is worse than a stall. Instead the one
        # GUARANTEED deadlock (the parent holds a key its child will wait on,
        # while the parent may go on to wait for that child) is caught here,
        # loudly, at dispatch. Ordinary cross-execution contention on the same
        # key is unaffected and still snoozes normally.
        def detect_lock_deadlock(child_class, child_inputs, context)
          held = held_lock_keys(context)
          return nil if held.empty?

          collision = child_lock_keys(child_class, child_inputs).find { |key| held.include?(key) }
          return nil unless collision

          RubyReactor.Failure(deadlock_message(collision, child_class, context))
        end

        def child_lock_keys(child_class, child_inputs)
          keys = []
          if child_class.respond_to?(:lock_config) && child_class.lock_config
            keys << child_class.lock_config[:key_proc].call(child_inputs)
          end

          # A semaphore with a single slot has the identical circular-wait
          # shape. Higher limits are contention, not guaranteed deadlock.
          semaphore = child_class.respond_to?(:semaphore_config) ? child_class.semaphore_config : nil
          keys << semaphore[:key_proc].call(child_inputs) if semaphore && semaphore[:limit] == 1

          keys.compact
        end

        def held_lock_keys(context)
          root = context.root_context || context
          Array(root.private_data[:held_lock_keys] || root.private_data["held_lock_keys"])
        end

        def deadlock_message(key, child_class, context)
          parent = context.reactor_class&.name || "the dispatching reactor"
          <<~MSG.strip
            async_reactor dispatch of #{child_class.name || "<anonymous>"} would deadlock: it declares the \
            lock key '#{key}', which #{parent} currently holds and will not release until it finishes.
            The child would snooze forever, and if #{parent} later reads this child's result it would wait \
            for work that can never start. Lock ownership is never shared across the async boundary — the \
            two run concurrently, so sharing it would break mutual exclusion outright.
            Fix, in order of preference:
              1. Use `compose` instead of `async_reactor` if the child belongs inside #{parent}'s critical \
            section and its result is needed — waiting for it means the work is sequential anyway.
              2. Narrow the lock keys, if parent and child actually protect different resources.
              3. Restructure so the locked reactor never reads the child's result — fire-and-forget, and \
            verify in the child itself or in a successor reactor outside the lock window.
          MSG
        end

        # `RSpec::TestSubject`'s `async: false` clears the dispatch marker to run
        # the whole reactor in one process.
        def run_inline?(context)
          config = context.reactor_class&.steps&.[](context.current_step)
          config.respond_to?(:async_dispatch?) && !config.async_dispatch?
        end

        def run_inline(child_class, child_inputs, context)
          result = child_class.run(child_inputs)
          store_reference(context, execution_id: (result.execution_id if result.respond_to?(:execution_id)),
                                   child_class: child_class)
          # Success(nil) for the same reason dispatch returns it: `result(:name)`
          # must route through the reference (which now points at an already
          # terminal child) rather than through a recorded value.
          RubyReactor.Success(nil)
        end

        def dispatch(child_class, child_inputs, context)
          child_context = build_child_context(child_class, child_inputs, context)
          assign_ordered_lock_nonce!(child_class, child_context)

          # Persist BEFORE enqueue (F2) — the payload is identity-only.
          child_context.status = :running
          save(child_context, child_class)

          # The reference is written synchronously, by the process that is about
          # to keep running other steps, so there is no cross-process race on it
          # (unlike the child's eventual result, which the child itself writes).
          store_reference(context, execution_id: child_context.context_id, child_class: child_class)
          log_dispatch(context, child_class, child_context)

          RubyReactor.configuration.async_router.perform_async(
            child_context.context_id, RubyReactor.reactor_storage_name(child_class)
          )

          RubyReactor.Success(nil)
        end

        def build_child_context(child_class, child_inputs, context)
          child_context = RubyReactor::Context.new(child_inputs, child_class)
          # Linked for traceability only — the child is NOT nested inside the
          # parent's context tree, because it must survive the parent finishing.
          child_context.parent_context_id = context.context_id
          child_context
        end

        def assign_ordered_lock_nonce!(child_class, child_context)
          return unless child_class.respond_to?(:ordered_lock_config) && child_class.ordered_lock_config

          config = child_class.ordered_lock_config
          key = config[:key_proc].call(child_context.inputs)
          nonce, epoch = RubyReactor::OrderedLock.assign(key, ttl: config[:ttl])

          child_context.private_data[:ordered_lock] = {
            key: key, nonce: nonce, epoch: epoch,
            poison_pill_timeout: config[:poison_pill_timeout],
            ttl: config[:ttl], strict: config.fetch(:strict, true)
          }
        end

        def store_reference(context, execution_id:, child_class:)
          context.composed_contexts[context.current_step] = {
            name: context.current_step,
            type: :async_reactor_ref,
            execution_id: execution_id,
            reactor_class_name: RubyReactor.reactor_storage_name(child_class),
            dispatched_at: Time.now
          }
        end

        def save(child_context, child_class)
          RubyReactor.configuration.storage_adapter.store_context(
            child_context.context_id,
            RubyReactor::ContextSerializer.serialize(child_context),
            RubyReactor.reactor_storage_name(child_class)
          )
        end

        # FR-012: the link between parent and child, machine-parseable. Matters
        # most here — a fire-and-forget child's failure may have no other surface
        # in the parent at all.
        def log_dispatch(context, child_class, child_context)
          RubyReactor.configuration.logger.info(
            "event=\"ruby_reactor.async_reactor.dispatched\" " \
            "reactor=#{context.reactor_class&.name.inspect} step=#{context.current_step.inspect} " \
            "execution_id=#{context.context_id.inspect} child_reactor=#{child_class.name.inspect} " \
            "child_execution_id=#{child_context.context_id.inspect}"
          )
        end
      end
    end
  end
end
