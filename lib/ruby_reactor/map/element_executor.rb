# frozen_string_literal: true

module RubyReactor
  module Map
    class ElementExecutor
      extend Helpers

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
        serialized_context = arguments[:serialized_context]

        if serialized_context
          context = ContextSerializer.deserialize(serialized_context)
          context.map_metadata = arguments
          reactor_class = context.reactor_class
        else
          # Deserialize inputs
          inputs = ContextSerializer.deserialize_value(serialized_inputs)

          # Resolve reactor class
          reactor_class = resolve_reactor_class(reactor_class_info)

          # Create context
          context = Context.new(inputs, reactor_class)
          context.map_metadata = arguments
        end
        storage = RubyReactor.configuration.storage_adapter

        # Execute
        executor = Executor.new(reactor_class, {}, context)

        if serialized_context
          executor.resume_execution
        else
          executor.execute
        end

        result = executor.result

        if result.is_a?(RetryQueuedResult)
          queue_next_batch(arguments) if batch_size
          return
        end

        # Store result

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
          timeout: 3600
        )
      end

      def self.queue_next_batch(arguments)
        storage = RubyReactor.configuration.storage_adapter
        map_id = arguments[:map_id]
        reactor_class_name = arguments[:parent_reactor_class_name]

        next_index = storage.increment_last_queued_index(map_id, reactor_class_name)
        total_count = storage.retrieve_map_metadata(map_id, reactor_class_name)["count"]

        return unless next_index < total_count

        parent_context = load_parent_context(arguments, reactor_class_name, storage)
        element = resolve_next_element(arguments, parent_context, next_index)
        serialized_inputs = build_serialized_inputs(arguments, parent_context, element)

        queue_element_job(arguments, map_id, next_index, serialized_inputs, reactor_class_name)
      end

      def self.load_parent_context(arguments, reactor_class_name, storage)
        parent_context_data = storage.retrieve_context(arguments[:parent_context_id], reactor_class_name)
        parent_reactor_class = Object.const_get(reactor_class_name)
        parent_context = Context.new(
          ContextSerializer.deserialize_value(parent_context_data["inputs"]),
          parent_reactor_class
        )
        parent_context.context_id = arguments[:parent_context_id]
        parent_context
      end

      def self.resolve_next_element(arguments, parent_context, next_index)
        parent_reactor_class = parent_context.reactor_class
        step_config = parent_reactor_class.steps[arguments[:step_name].to_sym]

        source_template = step_config.arguments[:source][:source]
        source = source_template.resolve(parent_context)
        source[next_index]
      end

      def self.build_serialized_inputs(arguments, parent_context, element)
        parent_reactor_class = parent_context.reactor_class
        step_config = parent_reactor_class.steps[arguments[:step_name].to_sym]

        mappings_template = step_config.arguments[:argument_mappings][:source]
        mappings = mappings_template.resolve(parent_context) || {}

        mapped_inputs = build_element_inputs(mappings, parent_context, element)
        ContextSerializer.serialize_value(mapped_inputs)
      end

      def self.queue_element_job(arguments, map_id, next_index, serialized_inputs, reactor_class_name)
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
      private_class_method :queue_next_batch, :load_parent_context,
                           :resolve_next_element, :build_serialized_inputs, :queue_element_job
    end
  end
end
