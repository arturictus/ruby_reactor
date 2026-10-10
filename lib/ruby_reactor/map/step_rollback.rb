# frozen_string_literal: true

module RubyReactor
  module Map
    # How a map step rolls back (009 R-01): a fan-out map distributed, one job
    # per started element (S-2); an inline map in process, in bounded reads
    # (S-4). Both report the same failures (I-7). Mixed into `Step::MapStep`.
    module StepRollback
      private

      # S-2: start the map's rollback once (its records, then the first
      # throw), then either aggregate a settled rollback or hand the run off
      # until the element jobs report (R-04, R-05). Re-entered by the owner's
      # resume, it finds the records and only checks for the settle.
      def distributed_rollback(map_id, step_name)
        storage = RubyReactor.configuration.storage_adapter
        map_class = context.reactor_class.name
        created, rollback = storage.start_map_rollback(map_id, map_class, **rollback_metadata(map_id, step_name))
        if created
          log_rollback("started", step_name, total: rollback["total"], batch_size: rollback["batch_size"])
          RubyReactor::Map::Dispatcher.dispatch_rollback_batch(map_id: map_id, parent_reactor_class_name: map_class)
        end
        total = rollback["total"].to_i
        if storage.count_map_rollback_outcomes(map_id, map_class) >= total
          return finish_rollback(step_name, total, distributed_failures(map_id, step_name))
        end

        raise RubyReactor::Error::RollbackHandedOff.new(map_id: map_id, reactor_class_name: map_class)
      end

      def rollback_metadata(map_id, step_name)
        storage = RubyReactor.configuration.storage_adapter
        map_class = context.reactor_class.name
        forward = storage.retrieve_map_metadata(map_id, map_class) || {}
        {
          total: storage.count_map_element_context_ids(map_id, map_class),
          batch_size: forward["batch_size"] || RubyReactor::Map::DEFAULT_BATCH_SIZE,
          step_name: step_name.to_s,
          owner_context_id: owner_context.context_id,
          owner_reactor_class_name: RubyReactor.reactor_storage_name(owner_context.reactor_class),
          reactor_class_info: forward["reactor_class_info"] || build_reactor_class_info(element_class, step_name)
        }
      end

      # The failures the element jobs reported, in position order (newest
      # first, as inline), read in bounded chunks (R-09).
      def distributed_failures(map_id, step_name)
        storage = RubyReactor.configuration.storage_adapter
        map_class = context.reactor_class.name
        reported = []
        unnamed = 0
        storage.each_map_rollback_outcome(map_id, map_class) do |position, outcome|
          unnamed += 1 if outcome["outcome"] == "context_unavailable" && outcome["index"].nil?
          next unless %w[failed element_in_flight].include?(outcome["outcome"])

          reported << [position, ContextSerializer.deserialize_value(outcome["failures"])]
        end
        unseen = lambda do |indexes|
          indexes.each_slice(1000).flat_map do |slice|
            slice.zip(storage.map_rollback_indexes_seen(map_id, map_class, slice)).reject(&:last).map(&:first)
          end
        end
        unavailable_entries(step_name, unnamed, unseen) + reported.sort_by(&:first).flat_map(&:last)
      end

      # S-4: in process, `Map::ROLLBACK_CHUNK` elements per read from the tail
      # of the element index, never all at once.
      def inline_rollback(map_id, step_name)
        storage = RubyReactor.configuration.storage_adapter
        map_class = context.reactor_class.name
        total = storage.count_map_element_context_ids(map_id, map_class)
        reported = []
        seen = Set.new
        unnamed = 0
        log_rollback("started", step_name, total: total, batch_size: RubyReactor::Map::ROLLBACK_CHUNK)
        (0...total).step(RubyReactor::Map::ROLLBACK_CHUNK) do |position|
          ids = storage.retrieve_map_element_context_ids_from_tail(map_id, map_class, position,
                                                                   RubyReactor::Map::ROLLBACK_CHUNK, total: total)
          ids.each do |id|
            outcome = inline_element_rollback(map_id, id, step_name)
            outcome["index"] ? seen << outcome["index"] : unnamed += 1
            reported.concat(ContextSerializer.deserialize_value(outcome["failures"])) if outcome["index"]
          end
        end
        unseen = ->(indexes) { indexes.reject { |index| seen.include?(index) } }
        finish_rollback(step_name, total, unavailable_entries(step_name, unnamed, unseen) + reported)
      end

      # Today's inline behavior: one wait for the element's lock, then report
      # it in flight.
      def inline_element_rollback(map_id, element_context_id, step_name)
        outcome = RubyReactor::Map::ElementRollback.call(map_id: map_id, element_context_id: element_context_id,
                                                         element_class: element_class, step_name: step_name)
        if outcome["outcome"] == "contended"
          outcome = { "index" => outcome["index"], "outcome" => "element_in_flight",
                      "failures" => ContextSerializer.serialize_value(
                        [rollback_entry(outcome["index"], :element_in_flight, "was still running at rollback time")]
                      ) }
        end
        log_rollback("element", step_name, index: outcome["index"], outcome: outcome["outcome"],
                                           failures: outcome["failures"].size)
        outcome
      end

      # Each element whose context expired is reported once (R-09, I2). The
      # parent's map reference counts the elements that started: set per
      # element inline, and to the total when a fan-out map completes. With
      # it, every started index no rollback saw is named, even when the index
      # list itself expired; without it (a failed fan-out map skipped some
      # indices), one unnamed entry per element whose row is gone.
      def unavailable_entries(step_name, unnamed, unseen)
        ref = Utils::FetchIndifferent.call(context.composed_contexts, step_name)
        started = ref && Utils::FetchIndifferent.call(ref, :started)
        missing = started ? unseen.call((0...started.to_i).to_a) : [nil] * unnamed
        missing.map { |index| rollback_entry(index, :context_unavailable, "context expired") }
      end

      # 010 R-13 (P-6): one call to the map's `undo_all` block, with the
      # completed elements' results (index order, read lazily, never all at
      # once), instead of replaying each element. A fan-out map reads its
      # result slots and dispatches no rollback jobs; an inline map reads its
      # element contexts one at a time, and an element an interruption left
      # `aborted` still replays its own completed steps (it has no result).
      def bulk_rollback(map_id, step_name, block)
        failures, count, results =
          dispatched_map_id(step_name) ? fan_out_completed(map_id) : inline_completed(map_id, step_name)
        failures << call_undo_all(block, results, step_name, count) if count.positive?
        finish_rollback(step_name, count, failures.compact)
      end

      def fan_out_completed(map_id)
        meta = rollback_storage.retrieve_map_metadata(map_id, context.reactor_class.name)
        return [[rollback_entry(nil, :context_unavailable, "map records expired")], 0, []] unless meta

        total = meta["count"].to_i
        failures = []
        count = 0
        each_result_slot(map_id, total) do |index, raw|
          next failures << rollback_entry(index, :context_unavailable, "context expired") if raw.nil?

          count += 1 if completed_slot?(raw)
        end
        results = Enumerator.new do |yielder|
          each_result_slot(map_id, total) do |_index, raw|
            yielder << ContextSerializer.deserialize_value(raw) if raw && completed_slot?(raw)
          end
        end
        [failures, count, results.lazy]
      end

      # ponytail: 1,000 slots per HMGET bounds memory; raise it if round trips dominate.
      def each_result_slot(map_id, total, &block)
        (0...total).each_slice(RubyReactor::Map::ResultEnumerator::DEFAULT_BATCH_SIZE) do |indexes|
          slots = rollback_storage.retrieve_map_result_slots(map_id, context.reactor_class.name, indexes)
          indexes.zip(slots).each(&block)
        end
      end

      def completed_slot?(raw)
        !(raw.is_a?(Hash) && (raw.key?("_error") || raw.key?("_halt") || raw.key?("_skipped")))
      end

      # Pass 1 replays aborted elements and counts completed ones; the lazy
      # pass 2 is what the block reads.
      def inline_completed(map_id, step_name)
        total = rollback_storage.count_map_element_context_ids(map_id, context.reactor_class.name)
        failures = []
        seen = Set.new
        unnamed = 0
        count = 0
        each_element(map_id, total) do |id, element|
          next unnamed += 1 unless element

          seen << Utils::FetchIndifferent.call(element.map_metadata || {}, :index).to_i
          case element.status.to_s
          when "completed" then count += 1
          when "aborted"
            outcome = inline_element_rollback(map_id, id, step_name)
            failures.concat(ContextSerializer.deserialize_value(outcome["failures"]))
          end
        end
        unseen = ->(indexes) { indexes.reject { |index| seen.include?(index) } }
        results = Enumerator.new do |yielder|
          each_element(map_id, total) do |_id, element|
            yielder << element_result(element) if element && element.status.to_s == "completed"
          end
        end
        [unavailable_entries(step_name, unnamed, unseen) + failures, count, results.lazy]
      end

      # Element contexts in index order (head of the index first), one loaded
      # at a time, `Map::ROLLBACK_CHUNK` ids per read.
      def each_element(map_id, total)
        storage_name = RubyReactor.reactor_storage_name(element_class)
        (0...total).each_slice(RubyReactor::Map::ROLLBACK_CHUNK) do |heads|
          ids = rollback_storage.retrieve_map_element_context_ids_from_tail(
            map_id, context.reactor_class.name, total - 1 - heads.last, heads.size, total: total
          ).reverse
          ids.each do |id|
            data = rollback_storage.retrieve_context(id, storage_name)
            yield id, data && Context.deserialize_from_retry(data)
          end
        end
      end

      # What the element returned, as the map collected it
      # (`ResultHandler#final_result`): its `returns` step, else every result.
      def element_result(element)
        klass = element.reactor_class || element_class
        klass.return_step ? element.get_result(klass.return_step) : element.intermediate_results
      end

      def call_undo_all(block, results, step_name, count)
        log_rollback("undo_all.started", step_name, count: count)
        outcome = begin
          block.call(results)
        rescue RubyReactor::Error::Rescuable => e
          e
        end
        failure = undo_all_failure(step_name, outcome)
        context.append_execution_trace({ type: :undo_all, step: step_name, count: count, timestamp: Time.now,
                                         result: failure ? failure[:message] : :ok })
        log_rollback("undo_all.completed", step_name, count: count, failed: failure ? 1 : 0)
        failure
      end

      def undo_all_failure(step_name, outcome)
        return unless outcome.is_a?(Exception) || outcome.is_a?(RubyReactor::Failure)

        error = outcome.is_a?(RubyReactor::Failure) ? outcome.error : outcome
        { step: step_name.to_sym, kind: :undo_all, reason: outcome.is_a?(Exception) ? :raised : :returned_failure,
          message: error.respond_to?(:message) ? error.message : error.to_s }
      end

      def rollback_storage
        RubyReactor.configuration.storage_adapter
      end

      def finish_rollback(step_name, total, failures)
        log_rollback("completed", step_name, total: total, failed: failures.size)
        return RubyReactor.Success() if failures.empty?

        RubyReactor.Failure("map :#{step_name} rollback incomplete", rollback_failures: failures)
      end

      def log_rollback(event, step_name, **fields)
        RubyReactor::Map.log("ruby_reactor.map.rollback.#{event}",
                             reactor: RubyReactor.reactor_storage_name(owner_context.reactor_class),
                             context_id: owner_context.context_id, map_step: step_name.to_s, **fields)
      end

      def rollback_entry(index, reason, message)
        RubyReactor::Map::ElementRollback.entry(context.current_step, index, reason, message)
      end
    end
  end
end
