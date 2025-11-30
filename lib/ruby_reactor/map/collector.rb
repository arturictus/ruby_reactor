# frozen_string_literal: true

module RubyReactor
  module Map
    class Collector
      extend Helpers

      # rubocop:disable Metrics/MethodLength
      def self.perform(arguments)
        arguments = arguments.transform_keys(&:to_sym)
        parent_context_id = arguments[:parent_context_id]
        map_id = arguments[:map_id]
        parent_reactor_class_name = arguments[:parent_reactor_class_name]
        step_name = arguments[:step_name]
        strict_ordering = arguments[:strict_ordering]

        storage = RubyReactor.configuration.storage_adapter

        # Retrieve parent context
        parent_context = load_parent_context_from_storage(
          parent_context_id,
          parent_reactor_class_name,
          storage
        )

        # Retrieve results
        serialized_results = storage.retrieve_map_results(map_id, parent_reactor_class_name,
                                                          strict_ordering: strict_ordering)

        results = serialized_results.map do |r|
          if r.is_a?(Hash) && r.key?("_error")
            RubyReactor::Failure(r["_error"])
          else
            RubyReactor::Success(r)
          end
        end

        # Get step config to check for collect block and other options
        parent_class = Object.const_get(parent_reactor_class_name)
        step_config = parent_class.steps[step_name.to_sym]

        collect_block = step_config.arguments[:collect_block][:source].value
        # TODO: Check allow_partial_failure option

        final_result = if collect_block
                         begin
                           # Pass all results (Success and Failure) to collect block
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

        # Resume execution
        resume_parent_execution(parent_context, step_name, final_result, storage)
      end
      # rubocop:enable Metrics/MethodLength
    end
  end
end
