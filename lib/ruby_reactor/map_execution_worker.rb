# frozen_string_literal: true

require "sidekiq"

module RubyReactor
  class MapExecutionWorker
    include Sidekiq::Worker

    # rubocop:disable Metrics/MethodLength, Metrics/PerceivedComplexity
    def perform(arguments)
      arguments = arguments.transform_keys(&:to_sym)
      _map_id = arguments[:map_id]
      serialized_inputs = arguments[:serialized_inputs]
      reactor_class_info = arguments[:reactor_class_info]
      _strict_ordering = arguments[:strict_ordering]
      parent_context_id = arguments[:parent_context_id]
      parent_reactor_class_name = arguments[:parent_reactor_class_name]
      step_name = arguments[:step_name]
      storage = RubyReactor.configuration.storage_adapter

      # Deserialize inputs
      inputs = RubyReactor::ContextSerializer.deserialize_value(serialized_inputs)
      source = inputs[:source]
      mappings = inputs[:mappings]

      # Load parent context
      parent_context_data = storage.retrieve_context(parent_context_id, parent_reactor_class_name)
      parent_context = RubyReactor::Context.deserialize_from_retry(parent_context_data)

      # Determine reactor class
      reactor_class = if reactor_class_info["type"] == "class"
                        Object.const_get(reactor_class_info["name"])
                      elsif reactor_class_info["type"] == "inline"
                        parent_reactor = Object.const_get(reactor_class_info["parent"])
                        parent_reactor.steps[reactor_class_info["step"].to_sym]
                                      .arguments[:mapped_reactor_class][:source].value
                      else
                        raise "Unknown reactor type: #{reactor_class_info["type"]}"
                      end

      results = []

      # Execute map loop
      source.each_with_index do |element, _index|
        # Build inputs for the mapped reactor
        # We need to replicate MapStep#build_mapped_inputs logic here
        # But MapStep isn't available as an instance.
        # We can use a helper or duplicate the logic.
        # The logic is simple: resolve arguments against element.

        element_inputs = {}
        mappings.each do |input_name, source_template|
          # We need to resolve the template against the element
          # But the template is a RubyReactor::Template::Element
          # We can manually resolve it.

          if source_template.is_a?(RubyReactor::Template::Element)
            # It refers to the element itself or a path within it
            val = element
            source_template.path&.split(".")&.each do |segment|
              val = val[segment] || val[segment.to_sym]
            end
            element_inputs[input_name] = val
          else
            # Other templates might need parent context
            element_inputs[input_name] = source_template.resolve(parent_context)
          end
        end

        # Run reactor
        result = reactor_class.run(element_inputs)

        # Store result
        results << result
      end

      # Collect results
      # If collect block was defined... wait, collect block is in the step definition.
      # We need to access it.

      step_config = Object.const_get(parent_reactor_class_name).steps[step_name.to_sym]
      collect_block = step_config.arguments[:collect_block][:source].value

      final_result = if collect_block
                       collect_block.call(results.map(&:value))
                     else
                       # Default collection: hash of results keyed by map name
                       # Wait, MapStep#run returns { map_name => [results] }
                       # We should match that.
                       results.map(&:value)
                     end

      # Update parent context
      # We need to set the result for the map step
      parent_context.set_result(step_name.to_sym, { step_name.to_sym => final_result })

      # Resume parent execution
      executor = RubyReactor::Executor.new(parent_context.reactor_class, {}, parent_context)
      executor.resume_execution
    end
    # rubocop:enable Metrics/MethodLength, Metrics/PerceivedComplexity
  end
end
