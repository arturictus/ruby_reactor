# frozen_string_literal: true

module RubyReactor
  module Map
    # Rolls back ONE element of a map (009 R-07): the element's own undo
    # stack, replayed under its liveness lock and saved after every undone
    # entry, so a redelivery resumes after the last one (only the entry that
    # was cut off may run again). The inline path calls `.call` in process; a
    # fan-out map's `MapElementRollbackWorker` calls `.perform`.
    class ElementRollback
      extend Helpers

      # The element context row is gone: its index went with it.
      def self.unavailable(step_name)
        { "index" => nil, "outcome" => "context_unavailable",
          "failures" => ContextSerializer.serialize_value([entry(step_name, nil, :context_unavailable,
                                                                 "context expired")]) }
      end

      # `{ "index", "outcome", "failures" }` (DM §5), with `failures`
      # serialized. Outcome `contended`, never stored, means the element's lock
      # was still held after `wait`.
      def self.call(map_id:, element_context_id:, element_class:, step_name:, wait: Step::MapStep::ELEMENT_LOCK_WAIT)
        storage_name = RubyReactor.reactor_storage_name(element_class)
        data = element_context_id && RubyReactor.configuration.storage_adapter.retrieve_context(element_context_id,
                                                                                                storage_name)
        return unavailable(step_name) unless data

        element = Context.deserialize_from_retry(data)
        index = Utils::FetchIndifferent.call(element.map_metadata || {}, :index).to_i
        lock = acquire_element_lock(map_id, index, wait)
        return outcome(index, "contended") if lock == :held

        begin
          roll_back(element, element_class, index, step_name)
        ensure
          lock.release if lock.respond_to?(:release)
        end
      end

      # A completed element, or an aborted one (an inline run interrupted in
      # it, which kept the undo entries of the steps it completed), undoes;
      # a failed one already rolled itself back, and a halted or superseded
      # running one did nothing to undo.
      def self.roll_back(element, element_class, index, step_name)
        return outcome(index, "not_needed") unless %w[completed aborted].include?(element.status.to_s)

        executor = Executor.new(element.reactor_class || element_class, {}, element)
        executor.undo_all { executor.checkpoint! }
        executor.checkpoint!
        tag = { map_step: step_name.to_sym, element_index: index }
        failures = executor.compensation_manager.rollback_failures.map { |failure| failure.merge(tag) }
        outcome(index, failures.empty? ? "undone" : "failed", failures)
      end

      # The job's body. A contended lock requeues the job, storing nothing,
      # up to `lock_snooze_max_attempts` times before reporting the element
      # in flight: two contexts of one index in the same batch then serialize
      # instead of one reporting a false failure (R-07).
      def self.perform(arguments)
        args = Helpers.normalize_arguments(arguments)
        map_id = args[:map_id]
        map_class = args[:parent_reactor_class_name]
        storage = RubyReactor.configuration.storage_adapter
        return if storage.map_rollback_outcome_stored?(map_id, map_class, args[:position])

        attempt = args[:attempt].to_i
        result = call(map_id: map_id, element_context_id: args[:element_context_id],
                      element_class: resolve_reactor_class(args[:reactor_class_info]), step_name: args[:step_name],
                      wait: attempt.zero? ? Step::MapStep::ELEMENT_LOCK_WAIT : 0)
        if result["outcome"] == "contended"
          return requeue(args, attempt) unless snooze_exhausted?(attempt)

          result = in_flight(result["index"], args[:step_name])
        end
        return unless storage.store_map_rollback_outcome(map_id, map_class, args[:position], result)

        log_outcome(args, result)
        Dispatcher.dispatch_rollback_batch(map_id: map_id, parent_reactor_class_name: map_class) if batch_end?(args)
        signal_owner_if_settled(args)
      end

      def self.in_flight(index, step_name)
        outcome(index, "element_in_flight",
                [entry(step_name, index, :element_in_flight, "was still running at rollback time")])
      end

      def self.snooze_exhausted?(attempt)
        max = RubyReactor.configuration.lock_snooze_max_attempts
        max != :infinity && attempt >= max
      end

      def self.requeue(args, attempt)
        config = RubyReactor.configuration
        config.async_router.perform_map_element_rollback_in(
          Worker.snooze_delay(config, nil), **args.slice(*ROLLBACK_JOB_ARGS), attempt: attempt + 1
        )
      end

      # The position that ends a throw claims the next one (R-02).
      def self.batch_end?(args)
        batch_size = args[:batch_size].to_i
        batch_size.positive? && ((args[:position].to_i + 1) % batch_size).zero?
      end

      # The handshake's job side (R-05): only once the hand-off is saved, so
      # the owner never resumes from a stale blob — and never in inline job
      # mode, where the map settles before any hand-off exists.
      def self.signal_owner_if_settled(args)
        storage = RubyReactor.configuration.storage_adapter
        map_id = args[:map_id]
        map_class = args[:parent_reactor_class_name]
        meta = storage.retrieve_map_rollback_metadata(map_id, map_class)
        return unless meta && storage.count_map_rollback_outcomes(map_id, map_class) >= meta["total"].to_i
        return unless storage.map_rollback_handed_off?(map_id, map_class)
        return unless storage.claim_map_rollback_signal(map_id, map_class)

        RubyReactor.configuration.async_router.perform_async(args[:owner_context_id], args[:owner_reactor_class_name])
      end

      def self.log_outcome(args, result)
        Map.log("ruby_reactor.map.rollback.element",
                reactor: args[:owner_reactor_class_name], context_id: args[:owner_context_id],
                map_step: args[:step_name], index: result["index"], outcome: result["outcome"],
                failures: Array(result["failures"]).size)
      end

      def self.outcome(index, outcome, failures = [])
        { "index" => index, "outcome" => outcome, "failures" => ContextSerializer.serialize_value(failures) }
      end

      # A rollback failure entry for the element as a whole (008 shape).
      def self.entry(step_name, index, reason, message)
        step = step_name.to_sym
        { step: step, kind: :undo, key: nil, reason: reason, map_step: step, element_index: index,
          message: "map element #{index} #{message}" }
      end

      def self.acquire_element_lock(map_id, index, wait)
        return nil if ElementExecutor.inline_testing_mode?

        lock = RubyReactor::Lock.new("map_element:#{map_id}:#{index}", owner: SecureRandom.uuid,
                                                                       ttl: RubyReactor.configuration.context_lock_ttl,
                                                                       wait: wait)
        lock.acquire
        lock
      rescue RubyReactor::Lock::AcquisitionError
        :held
      end

      ROLLBACK_JOB_ARGS = %i[map_id position element_context_id reactor_class_info parent_reactor_class_name step_name
                             batch_size owner_context_id owner_reactor_class_name].freeze

      private_class_method :roll_back, :in_flight, :snooze_exhausted?, :requeue, :batch_end?,
                           :signal_owner_if_settled, :log_outcome, :acquire_element_lock
    end
  end
end
