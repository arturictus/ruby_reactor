# frozen_string_literal: true

module RubyReactor
  module Map
    class Execution
      extend Helpers

      def self.perform(arguments)
        arguments = arguments.transform_keys(&:to_sym)
        storage = RubyReactor.configuration.storage_adapter

        # Extract arguments
        parent_context_id = arguments[:parent_context_id]
        parent_reactor_class_name = arguments[:parent_reactor_class_name]
        step_name = arguments[:step_name]

        # Load context and resolve reactor class
        parent_context = load_parent_context_from_storage(
          parent_context_id,
          parent_reactor_class_name,
          storage
        )
        reactor_class = resolve_reactor_class(arguments[:reactor_class_info])

        # Deserialize inputs
        inputs = ContextSerializer.deserialize_value(arguments[:serialized_inputs])
        source = inputs[:source]
        mappings = inputs[:mappings]

        # Execute all elements
        # Execute all elements
        results = execute_all_elements(
          source, mappings, reactor_class, parent_context,
          arguments[:map_id], storage, parent_reactor_class_name, arguments[:strict_ordering]
        )

        # Collect and apply results
        step_config = Object.const_get(parent_reactor_class_name).steps[step_name.to_sym]
        final_result = apply_collect_block(results, step_config)

        # Resume parent execution
        resume_parent_execution(parent_context, step_name, final_result, storage)
      end

      def self.execute_all_elements(source, mappings, reactor_class, parent_context, map_id, storage,
                                    parent_reactor_class_name, strict_ordering)
        source.map.with_index do |element, index|
          element_inputs = build_element_inputs(mappings, parent_context, element)
          result = reactor_class.run(element_inputs)

          # Store result in Redis
          if result.success?
            storage.store_map_result(map_id, index, result.value, parent_reactor_class_name,
                                     strict_ordering: strict_ordering)
          else
            storage.store_map_result(map_id, index, { _error: result.error }, parent_reactor_class_name,
                                     strict_ordering: strict_ordering)
          end

          result
        end
      end
      private_class_method :execute_all_elements
    end
  end
end
