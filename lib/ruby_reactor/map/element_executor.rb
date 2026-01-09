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

          # Ensure inputs are present (fallback to serialized_inputs if missing from context)
          if context.inputs.empty? && serialized_inputs
            context.inputs = ContextSerializer.deserialize_value(serialized_inputs)
          end
        else
          # Deserialize inputs
          inputs = ContextSerializer.deserialize_value(serialized_inputs)

          # Resolve reactor class
          reactor_class = resolve_reactor_class(reactor_class_info)

          # Create context
          context = Context.new(inputs, reactor_class)
          context.parent_context_id = parent_context_id
          context.map_metadata = arguments
        end

        storage = RubyReactor.configuration.storage_adapter
        storage.store_map_element_context_id(map_id, context.context_id, parent_reactor_class_name)

        # Execute
        executor = Executor.new(reactor_class, {}, context)

        if serialized_context
          executor.resume_execution
        else
          executor.execute
        end

        result = executor.result

        if result.is_a?(RetryQueuedResult)
          trigger_next_batch_if_needed(arguments, index, batch_size)
          return
        end

        # Store result

        if result.success?
          storage.store_map_result(map_id, index,
                                   ContextSerializer.serialize_value(result.value),
                                   parent_reactor_class_name,
                                   strict_ordering: strict_ordering)
        else
          # Store error
          storage.store_map_result(map_id, index, { _error: result.error }, parent_reactor_class_name,
                                   strict_ordering: strict_ordering)
        end

        # Decrement counter
        new_count = storage.decrement_map_counter(map_id, parent_reactor_class_name)

        # Trigger next batch if it's the last element of the current batch
        trigger_next_batch_if_needed(arguments, index, batch_size)

        return unless new_count.zero?

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

      # Legacy helpers resolved_next_element, build_serialized_inputs, queue_element_job
      # are REMOVED as they are no longer used for self-queuing.

      # Basic helper to build inputs for the CURRENT element (still needed for perform)
      # Wait, perform uses `serialized_inputs` passed to it.
      # We don't need `build_element_inputs` here?
      # `perform` uses `params[:serialized_inputs]`.
      # So we can remove input building helpers too?
      # Let's check if they are used elsewhere.
      # `resolve_reactor_class` is used in `perform`.
      # `build_element_inputs` is likely in Helpers or mixed in?

      def self.trigger_next_batch_if_needed(arguments, index, batch_size)
        return unless batch_size && ((index + 1) % batch_size).zero?

        # Trigger Dispatcher for next batch
        next_batch_args = arguments.dup
        next_batch_args[:continuation] = true
        RubyReactor::Map::Dispatcher.perform(next_batch_args)
      end

      private_class_method :load_parent_context, :trigger_next_batch_if_needed
    end
  end
end
