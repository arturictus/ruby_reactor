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
        results = execute_all_elements(source, mappings, reactor_class, parent_context)

        # Collect and apply results
        step_config = Object.const_get(parent_reactor_class_name).steps[step_name.to_sym]
        final_result = apply_collect_block(results, step_config)

        # Resume parent execution
        resume_parent_execution(parent_context, step_name, final_result, storage)
      end

      def self.execute_all_elements(source, mappings, reactor_class, parent_context)
        source.map do |element|
          element_inputs = build_element_inputs(mappings, parent_context, element)
          reactor_class.run(element_inputs)
        end
      end
      private_class_method :execute_all_elements
    end
  end
end
