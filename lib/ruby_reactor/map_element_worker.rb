# frozen_string_literal: true

module RubyReactor
  class MapElementWorker
    include Sidekiq::Worker

    # rubocop:disable Metrics/MethodLength
    def perform(arguments)
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

    private

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
  end
end
