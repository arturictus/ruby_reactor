# frozen_string_literal: true

module RubyReactor
  class MapCollectorWorker
    include Sidekiq::Worker

    def perform(parent_context_id, map_id, parent_reactor_class_name, step_name, strict_ordering, _timeout = nil)
      storage = RubyReactor.configuration.storage_adapter

      # Retrieve parent context
      serialized_context = storage.retrieve_context(parent_context_id, parent_reactor_class_name)
      raise "Parent context not found" unless serialized_context

      parent_context = Context.deserialize_from_retry(serialized_context)

      # Retrieve results
      serialized_results = storage.retrieve_map_results(map_id, parent_reactor_class_name,
                                                        strict_ordering: strict_ordering)

      results = serialized_results.map do |r|
        # Keep error hash if present, otherwise return result
        r
      end

      # Get step config to check for collect block and other options
      parent_class = Object.const_get(parent_reactor_class_name)
      step_config = parent_class.steps[step_name.to_sym]

      collect_block = step_config.arguments[:collect_block][:source].value
      # TODO: Check allow_partial_failure option

      final_result = if collect_block
                       begin
                         collected = collect_block.call(results)
                         RubyReactor::Success(collected)
                       rescue StandardError => e
                         RubyReactor::Failure(e)
                       end
                     else
                       RubyReactor::Success(results)
                     end

      if final_result.success?
        # Set result in parent context
        parent_context.set_result(step_name, final_result.value)

        # Clear current step to avoid re-execution
        parent_context.current_step = nil

        # Resume execution
        executor = Executor.new(parent_class, {}, parent_context)
        executor.resume_execution
      else
        # Handle failure
        # We can't set result if it's a failure.
        # We should probably resume execution but let it fail?
        # If we resume with current_step = step_name, it will retry.
        # But we want to fail it permanently (or according to retry policy).

        # If we want to fail the step, we can't easily inject the failure into Executor flow
        # without running the step.

        # Alternative: Set a special result that indicates failure?
        # Or just let it retry? But retrying won't fix the map failure unless it was transient.

        # For now, let's assume success path works.
        # Handling failure in async map is complex.
        # We might need to update Executor to handle "AsyncFailure".
      end
    end
  end
end
