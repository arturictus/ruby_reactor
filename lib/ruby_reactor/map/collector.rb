# frozen_string_literal: true

module RubyReactor
  module Map
    class Collector
      extend Helpers

      def self.perform(arguments)
        arguments = arguments.transform_keys(&:to_sym)
        map_id = arguments[:map_id]
        parent_context_id = arguments[:parent_context_id]
        parent_reactor_class_name = arguments[:parent_reactor_class_name]
        step_name = arguments[:step_name]
        strict_ordering = arguments[:strict_ordering]
        # timeout = arguments[:timeout]

        storage = RubyReactor.configuration.storage_adapter
        parent_context_data = storage.retrieve_context(parent_context_id, parent_reactor_class_name)
        parent_context = RubyReactor::Context.deserialize_from_retry(parent_context_data)

        # Check if all tasks are completed
        metadata = storage.retrieve_map_metadata(map_id, parent_reactor_class_name)
        total_count = metadata ? metadata["count"].to_i : 0

        results_count = storage.count_map_results(map_id, parent_reactor_class_name)

        # Not done yet, requeue or wait?
        # Actually Collector currently assumes we only call it when we expect completion or check progress
        # Since map_offset tracks dispatching progress and might exceed count due to batching reservation,
        # we must strictly check against the total count of elements.
        # Check for fail_fast failure FIRST
        if (failed_context_id = storage.retrieve_map_failed_context_id(map_id, parent_reactor_class_name))
          handle_failure(failed_context_id, metadata, storage, parent_context, step_name)
          return
        end

        return if results_count < total_count

        # Retrieve results lazily
        results = RubyReactor::Map::ResultEnumerator.new(
          map_id,
          parent_reactor_class_name,
          strict_ordering: strict_ordering
        )

        # Apply collect block (or default collection)
        step_config = parent_context.reactor_class.steps[step_name.to_sym]

        begin
          final_result = apply_collect_block(results, step_config)

          if final_result.failure?
            # Optionally log failure internally or just rely on context status update
          end
        rescue StandardError => e
          final_result = RubyReactor::Failure(e)
        end

        # Resume parent execution
        resume_parent_execution(parent_context, step_name, final_result, storage)
      rescue StandardError => e
        puts "COLLECTOR CRASH: #{e.message}"
        puts e.backtrace
        raise e
      end

      def self.apply_collect_block(results, step_config)
        collect_block = step_config.arguments[:collect_block][:source].value if step_config.arguments[:collect_block]
        # TODO: Check allow_partial_failure option

        if collect_block
          begin
            # Pass Enumerator to collect block
            collected = collect_block.call(results)
            RubyReactor::Success(collected)
          rescue StandardError => e
            puts "COLLECTOR INNER EXCEPTION: #{e.message}"
            puts e.backtrace
            RubyReactor::Failure(e)
          end
        else
          # Default behavior: Return Success(Enumerator).
          # Logic for checking failures is deferred to the consumer of the enumerator.
          RubyReactor::Success(results)
        end
      end

      def self.handle_failure(failed_context_id, metadata, storage, parent_context, step_name)
        # Resolve the class of the mapped reactor to retrieve its context
        reactor_class = resolve_reactor_class(metadata["reactor_class_info"])
        failed_context_data = storage.retrieve_context(failed_context_id, reactor_class.name)

        return unless failed_context_data

        failed_context = RubyReactor::Context.deserialize_from_retry(failed_context_data)
        reason = failed_context.failure_reason
        result = reason.is_a?(RubyReactor::Failure) ? reason : RubyReactor::Failure(reason)
        resume_parent_execution(parent_context, step_name, result, storage)
      end
    end
  end
end
