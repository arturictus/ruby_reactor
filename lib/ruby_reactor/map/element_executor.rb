# frozen_string_literal: true

module RubyReactor
  module Map
    class ElementExecutor
      # rubocop:disable Metrics/MethodLength
      def self.perform(arguments)
        arguments = arguments.transform_keys(&:to_sym)
        map_id = arguments[:map_id]
        _element_id = arguments[:element_id]
        index = arguments[:index]
        serialized_inputs = arguments[:serialized_inputs]
        reactor_class_info = arguments[:reactor_class_info]
        strict_ordering = arguments[:strict_ordering]
        parent_context_id = arguments[:parent_context_id]
        parent_reactor_class_name = arguments[:parent_reactor_class_name]
        step_name = arguments[:step_name]
        batch_size = arguments[:batch_size]
        # rubocop:enable Metrics/MethodLength
        # Deserialize inputs
        inputs = ContextSerializer.deserialize_value(serialized_inputs)
        storage = RubyReactor.configuration.storage_adapter

        # Resolve reactor class
        reactor_class = resolve_reactor_class(reactor_class_info)

        # Create context
        context = Context.new(inputs, reactor_class)

        # Execute
        executor = Executor.new(reactor_class, {}, context)
        executor.execute

        result = executor.result

        # Store result

        if result.success?
          storage.store_map_result(map_id, index, result.value, parent_reactor_class_name,
                                   strict_ordering: strict_ordering)
        else
          # Store error
          storage.store_map_result(map_id, index, { _error: result.error }, parent_reactor_class_name,
                                   strict_ordering: strict_ordering)
        end

        # Decrement counter
        new_count = storage.decrement_map_counter(map_id, parent_reactor_class_name)

        queue_next_batch(arguments) if batch_size

        return unless new_count.zero?

        # Trigger collection
        RubyReactor.configuration.async_router.perform_map_collection_async(
          parent_context_id: parent_context_id,
          map_id: map_id,
          parent_reactor_class_name: parent_reactor_class_name,
          step_name: step_name,
          strict_ordering: strict_ordering,
          timeout: nil
        )
      end

      def self.resolve_reactor_class(info)
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

      def self.queue_next_batch(arguments)
        storage = RubyReactor.configuration.storage_adapter
        map_id = arguments[:map_id]
        reactor_class_name = arguments[:parent_reactor_class_name]

        next_index = storage.increment_last_queued_index(map_id, reactor_class_name)

        metadata = storage.retrieve_map_metadata(map_id, reactor_class_name)
        total_count = metadata["count"]

        return unless next_index < total_count

        # Load parent context to resolve source
        parent_context_data = storage.retrieve_context(arguments[:parent_context_id], reactor_class_name)
        parent_reactor_class = Object.const_get(reactor_class_name)
        parent_context = Context.new(ContextSerializer.deserialize_value(parent_context_data["inputs"]),
                                     parent_reactor_class)
        parent_context.context_id = arguments[:parent_context_id]

        # Get step config
        step_config = parent_reactor_class.steps[arguments[:step_name].to_sym]

        # Extract source template
        source_arg_config = step_config.arguments[:source]
        source_template = source_arg_config[:source]

        # Resolve source
        source = source_template.resolve(parent_context)
        element = source[next_index]

        # Extract mappings template
        mappings_arg_config = step_config.arguments[:argument_mappings]
        mappings_template = mappings_arg_config[:source]
        mappings = mappings_template.resolve(parent_context) || {}

        # Build mapped inputs
        mapped_inputs = RubyReactor::Step::MapStep.build_mapped_inputs(
          mappings,
          parent_context,
          element
        )
        serialized_inputs = ContextSerializer.serialize_value(mapped_inputs)

        # Queue next job
        RubyReactor.configuration.async_router.perform_map_element_async(
          map_id: map_id,
          element_id: "#{map_id}:#{next_index}",
          index: next_index,
          serialized_inputs: serialized_inputs,
          reactor_class_info: arguments[:reactor_class_info],
          strict_ordering: arguments[:strict_ordering],
          parent_context_id: arguments[:parent_context_id],
          parent_reactor_class_name: reactor_class_name,
          step_name: arguments[:step_name],
          batch_size: arguments[:batch_size]
        )
      end
      private_class_method :resolve_reactor_class, :queue_next_batch
    end
  end
end
