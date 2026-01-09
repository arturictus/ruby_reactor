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
      def resume_parent_execution(parent_context, step_name, final_result, storage)
        executor = RubyReactor::Executor.new(parent_context.reactor_class, {}, parent_context)
        step_name_sym = step_name.to_sym

        if final_result.failure?
          parent_context.current_step = step_name_sym

          error = RubyReactor::Error::StepFailureError.new(
            final_result.error,
            step: step_name_sym,
            context: parent_context,
            original_error: final_result.error.is_a?(Exception) ? final_result.error : nil
          )

          # Pass backtrace if available
          if final_result.respond_to?(:backtrace) && final_result.backtrace
            error.set_backtrace(final_result.backtrace)
          elsif final_result.error.respond_to?(:backtrace)
            error.set_backtrace(final_result.error.backtrace)
          end

          failure_response = executor.result_handler.handle_execution_error(error)
          # Manually update context status since we're not running executor loop
          executor.send(:update_context_status, failure_response)
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

        storage.store_context(
          parent_context.context_id,
          ContextSerializer.serialize(parent_context),
          parent_context.reactor_class.name
        )
      end
    end
  end
end
