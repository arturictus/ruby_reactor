# frozen_string_literal: true

module RubyReactor
  class MapElementWorker
    include Sidekiq::Worker

    def perform(map_id, index, serialized_inputs, reactor_class_info, strict_ordering, parent_context_id,
                parent_reactor_class_name, step_name)
      # Deserialize inputs
      inputs = ContextSerializer.deserialize_value(serialized_inputs)

      # Resolve reactor class
      reactor_class = resolve_reactor_class(reactor_class_info)

      # Create context
      context = Context.new(inputs, reactor_class)

      # Execute
      executor = Executor.new(reactor_class, {}, context)
      executor.execute

      result = executor.result

      # Store result
      storage = RubyReactor.configuration.storage_adapter

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

      return unless new_count == 0

      # Trigger collection
      MapCollectorWorker.perform_async(map_id, parent_context_id, parent_reactor_class_name, strict_ordering,
                                       step_name)
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
