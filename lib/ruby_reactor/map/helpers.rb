# frozen_string_literal: true

module RubyReactor
  module Map
    # Shared helper methods for Map executors
    module Helpers
      # Resolves the reactor class from reactor_class_info
      def resolve_reactor_class(info)
        if info["type"] == "class"
          begin
            Object.const_get(info["name"])
          rescue NameError
            RubyReactor::Registry.find(info["name"])
          end
        elsif info["type"] == "inline"
          parent_class = Object.const_get(info["parent"])
          step_config = parent_class.steps[info["step"].to_sym]
          step_config.arguments[:mapped_reactor_class][:source].value
        else
          raise "Unknown reactor class info: #{info}"
        end
      end

      # Loads parent context from storage
      def load_parent_context_from_storage(parent_context_id, reactor_class_name, storage)
        parent_context_data = storage.retrieve_context(parent_context_id, reactor_class_name)
        RubyReactor::Context.deserialize_from_retry(parent_context_data)
      end

      # Builds mapped inputs for a single element
      def build_element_inputs(mappings, parent_context, element)
        RubyReactor::Step::MapStep.build_mapped_inputs(mappings, parent_context, element)
      end

      # Applies collect block to results
      def apply_collect_block(results, step_config)
        collect_block = step_config.arguments[:collect_block][:source].value

        if collect_block
          # Pass all results (Success and Failure) to collect block
          begin
            collected = collect_block.call(results)
            RubyReactor::Success(collected)
          rescue StandardError => e
            RubyReactor::Failure(e)
          end
        else
          # Default behavior: fail if any failure
          first_failure = results.find(&:failure?)
          first_failure || RubyReactor::Success(results.map(&:value))
        end
      end

      # Resumes parent reactor execution after map completion
      def resume_parent_execution(parent_context, step_name, final_result, storage) # rubocop:disable Metrics/MethodLength
        executor = RubyReactor::Executor.new(parent_context.reactor_class, {}, parent_context)
        step_name_sym = step_name.to_sym

        if final_result.failure?
          parent_context.current_step = step_name_sym

          error = RubyReactor::Error::StepFailureError.new(
            final_result.error,
            step: step_name_sym,
            context: parent_context,
            original_error: final_result.error.is_a?(Exception) ? final_result.error : nil,
            exception_class: final_result.respond_to?(:exception_class) ? final_result.exception_class : nil
          )

          # Pass backtrace if available
          if final_result.respond_to?(:backtrace) && final_result.backtrace
            error.set_backtrace(final_result.backtrace)
          elsif final_result.error.respond_to?(:backtrace)
            error.set_backtrace(final_result.error.backtrace)
          end

          # Bracket the rollback with reactor lifecycle events so that
          # compensation/undo spans nest under a reactor span (and stay attached
          # to the originating trace), mirroring the success path's
          # resume_execution. Without this, rollback runs in the collector worker
          # with no active reactor span and the undo/compensation spans orphan.
          executor.middlewares.on(:start_reactor, parent_context.reactor_class.name, parent_context.inputs,
                                  parent_context)
          failure_response = nil
          begin
            failure_response = executor.result_handler.handle_execution_error(error)
            # Manually update context status since we're not running executor loop
            executor.send(:update_context_status, failure_response)
          ensure
            executor.middlewares.on(:failed_reactor, parent_context.reactor_class.name, failure_response,
                                    parent_context)
          end
        else
          parent_context.set_result(step_name_sym, final_result.value)

          # Manually update execution trace to reflect completion
          # This is necessary because resume_execution continues from the NEXT step
          # and the async step (which returned AsyncResult) needs to be marked as done with actual value
          parent_context.execution_trace << {
            type: :result,
            step: step_name_sym,
            timestamp: Time.now,
            value: final_result.value,
            status: :success
          }

          parent_context.current_step = nil
          executor.resume_execution
        end

        # Checkpoint the ROOT, not the sub (F9/C2). When the map is embedded in a
        # composed sub-reactor, parent_context is the *sub*; storing only the sub
        # would leave the root blob stale and a rehydrate-by-root-id resume would
        # lose the map's completion. Resolve the root (which embeds the sub's
        # post-map state via composed_contexts) and store that. For a top-level
        # map parent_context IS the root, so this is unchanged.
        root = parent_context.root_context || parent_context
        storage.store_context(
          root.context_id,
          ContextSerializer.serialize(root),
          root.reactor_class&.name || parent_context.reactor_class.name
        )
      end
    end
  end
end
