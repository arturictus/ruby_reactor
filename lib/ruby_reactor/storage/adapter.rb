# frozen_string_literal: true

module RubyReactor
  module Storage
    class Adapter
      def store_context(context_id, serialized_context, reactor_class_name)
        raise NotImplementedError
      end

      def retrieve_context(context_id, reactor_class_name)
        raise NotImplementedError
      end

      def store_map_result(map_id, index, serialized_result, reactor_class_name, strict_ordering: true)
        raise NotImplementedError
      end

      # The durable outcome of one `async_step`, keyed by (parent context, step
      # name). A separate worker writes it concurrently with the still-running
      # parent, so it deliberately lives OUTSIDE the parent's context blob —
      # writing into that blob from two processes would race.
      #
      # `record` is a plain hash: at minimum `status` ("dispatched" or
      # "completed"); a completed record also carries the serialized outcome.
      # The `dispatched` record is written before the job is enqueued, so it
      # doubles as the re-attach marker on recovery.
      def store_step_result(context_id, step_name, record, reactor_class_name)
        raise NotImplementedError
      end

      def retrieve_step_result(context_id, step_name, reactor_class_name)
        raise NotImplementedError
      end

      def scan_step_results(count: 1000)
        raise NotImplementedError
      end

      def retrieve_map_results(map_id, reactor_class_name, strict_ordering: true)
        raise NotImplementedError
      end

      def set_map_counter(map_id, count, reactor_class_name)
        raise NotImplementedError
      end

      def initialize_map_operation(map_id, count, reactor_class_info:, strict_ordering: true)
        raise NotImplementedError
      end

      def increment_map_counter(map_id, reactor_class_name)
        raise NotImplementedError
      end

      def decrement_map_counter(map_id, reactor_class_name)
        raise NotImplementedError
      end

      def decrement_map_counter_by(map_id, amount, reactor_class_name)
        raise NotImplementedError
      end

      def subscribe(channel, &block)
        raise NotImplementedError
      end

      def publish(channel, message)
        raise NotImplementedError
      end

      def expire(key, seconds)
        raise NotImplementedError
      end

      def store_correlation_id(correlation_id, context_id, reactor_class_name)
        raise NotImplementedError
      end

      def retrieve_context_id_by_correlation_id(correlation_id, reactor_class_name)
        raise NotImplementedError
      end

      def delete_correlation_id(correlation_id, reactor_class_name)
        raise NotImplementedError
      end

      def delete_context(context_id, reactor_class_name)
        raise NotImplementedError
      end

      def scan_reactors(pattern: "*", count: 50, include_dispatched_children: false)
        raise NotImplementedError
      end

      def scan_reactors_page(pattern: "*", cursor: "0", count: 50, include_dispatched_children: false)
        raise NotImplementedError
      end

      def find_context_by_id(context_id)
        raise NotImplementedError
      end

      def store_map_element_context_id(map_id, context_id, reactor_class_name)
        raise NotImplementedError
      end

      def retrieve_map_element_context_ids(map_id, reactor_class_name)
        raise NotImplementedError
      end

      def claim_map_owner_signal(map_id, reactor_class_name)
        raise NotImplementedError
      end

      def retrieve_map_result_slots(map_id, reactor_class_name, indexes)
        raise NotImplementedError
      end

      # Interrupt resume claims and attempt counts (010 DM §2, §3).
      def claim_interrupt_resume(context_id, reactor_class_name, step_name, serialized_payload)
        raise NotImplementedError
      end

      def retrieve_interrupt_resumes(context_id, reactor_class_name, step_names)
        raise NotImplementedError
      end

      def increment_interrupt_attempts(context_id, reactor_class_name, step_name)
        raise NotImplementedError
      end

      # Map rollback records (009 DM §5); see RedisMapRollback.
      %i[count_map_element_context_ids retrieve_map_element_context_ids_from_tail start_map_rollback
         retrieve_map_rollback_metadata claim_map_rollback_positions retrieve_map_rollback_offset
         store_map_rollback_outcome count_map_rollback_outcomes map_rollback_outcome_stored?
         stored_map_rollback_positions each_map_rollback_outcome map_rollback_indexes_seen
         mark_map_rollback_handed_off map_rollback_handed_off? claim_map_rollback_signal map_rollback_summary
         scan_map_rollbacks].each do |method|
        define_method(method) { |*, **| raise NotImplementedError }
      end
    end
  end
end
