# frozen_string_literal: true

module RubyReactor
  module Map
    # Shared helper methods for Map executors
    module Helpers
      # Resolves the reactor class from reactor_class_info
      def resolve_reactor_class(info)
        if info["type"] == "class"
          Object.const_get(info["name"])
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
        value = final_result.success? ? final_result.value : final_result
        parent_context.set_result(step_name.to_sym, value)
        parent_context.current_step = nil

        executor = RubyReactor::Executor.new(parent_context.reactor_class, {}, parent_context)
        executor.resume_execution

        storage.store_context(
          parent_context.context_id,
          ContextSerializer.serialize(parent_context),
          parent_context.reactor_class.name
        )
      end
    end
  end
end
