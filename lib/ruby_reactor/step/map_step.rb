# frozen_string_literal: true

module RubyReactor
  module Step
    class MapStep
      include RubyReactor::Step

      def self.run(arguments, context)
        return RubyReactor::Failure("Map source cannot be nil") if arguments[:source].nil?

        # Initialize map state in context if not present
        context.map_operations ||= {}

        if should_run_async?(arguments, context)
          run_async(arguments, context, context.current_step)
        else
          run_inline(arguments, context)
        end
      end

      def self.compensate(_reason, _arguments, _context)
        # TODO: Implement compensation for map steps
        RubyReactor.Success()
      end

      class << self
        def build_mapped_inputs(mappings, context, element)
          inputs = {}

          mappings.each do |mapped_input_name, source|
            value = if source.is_a?(RubyReactor::Template::Element)
                      # Handle element reference
                      # For now assuming element() refers to the current map's element
                      # In nested maps, we might need to check the name, but for now simple case
                      resolve_element(source, element)
                    else
                      source.resolve(context)
                    end
            inputs[mapped_input_name] = value
          end

          inputs
        end

        def resolve_element(template_element, current_element)
          # If path is provided, extract it
          if template_element.path
            extract_path(current_element, template_element.path)
          else
            current_element
          end
        end

        private

        def should_run_async?(arguments, context)
          arguments[:async] && !context.inline_async_execution
        end

        def run_inline(arguments, context)
          results = execute_inline_map(arguments, context)
          return results if results.is_a?(RubyReactor::Failure)

          process_results(results, arguments[:collect_block])
        end

        def execute_inline_map(arguments, context)
          results = []
          arguments[:source].each do |element|
            result = execute_single_element(element, arguments, context)
            return result unless result.success?

            results << result.value
          end
          results
        end

        def execute_single_element(element, arguments, context)
          mapped_inputs = build_mapped_inputs(arguments[:argument_mappings] || {}, context, element)
          child_context = RubyReactor::Context.new(mapped_inputs, arguments[:mapped_reactor_class])

          link_contexts(child_context, context)

          executor = RubyReactor::Executor.new(arguments[:mapped_reactor_class], {}, child_context)
          executor.execute
          executor.result
        end

        def link_contexts(child_context, parent_context)
          child_context.parent_context = parent_context
          child_context.root_context = parent_context.root_context || parent_context
          child_context.test_mode = parent_context.test_mode
          child_context.inline_async_execution = parent_context.inline_async_execution
        end

        def process_results(results, collect_block)
          if collect_block
            begin
              RubyReactor::Success(collect_block.call(results))
            rescue StandardError => e
              RubyReactor::Failure(e)
            end
          else
            RubyReactor::Success(results)
          end
        end

        def extract_path(value, path)
          if path.is_a?(Symbol) && value.respond_to?(:[])
            value[path]
          elsif path.is_a?(String)
            path.split(".").reduce(value) { |v, key| v&.send(:[], key) }
          elsif path.is_a?(Array)
            path.reduce(value) { |v, key| v&.send(:[], key) }
          elsif value.respond_to?(path)
            value.send(path)
          end
        end

        def run_async(arguments, context, step_name)
          map_id = "#{context.context_id}:#{step_name}"
          prepare_async_execution(context, map_id, arguments[:source].count)

          reactor_class_info = build_reactor_class_info(arguments[:mapped_reactor_class], context, step_name)

          if arguments[:batch_size]
            storage = RubyReactor.configuration.storage_adapter
            storage.set_last_queued_index(map_id, arguments[:batch_size] - 1, context.reactor_class.name)
            queue_fan_out(map_id: map_id, arguments: arguments, context: context,
                          reactor_class_info: reactor_class_info, step_name: step_name, limit: arguments[:batch_size])
          else
            queue_single_worker(map_id: map_id, arguments: arguments, context: context,
                                reactor_class_info: reactor_class_info, step_name: step_name)
          end

          RetryQueuedResult.new(step_name, 1, nil)
        end

        def prepare_async_execution(context, map_id, count)
          storage = RubyReactor.configuration.storage_adapter
          serialized_context = context.serialize_for_retry
          storage.store_context(context.context_id, serialized_context, context.reactor_class.name)
          storage.set_map_counter(map_id, count, context.reactor_class.name)
        end

        def build_reactor_class_info(mapped_reactor_class, context, step_name)
          if mapped_reactor_class.respond_to?(:name)
            { "type" => "class", "name" => mapped_reactor_class.name }
          else
            { "type" => "inline", "parent" => context.reactor_class.name, "step" => step_name.to_s }
          end
        end

        def queue_fan_out(map_id:, arguments:, context:, reactor_class_info:, step_name:, limit: nil)
          storage = RubyReactor.configuration.storage_adapter
          storage.initialize_map_operation(
            map_id, arguments[:source].count,
            strict_ordering: arguments[:strict_ordering], reactor_class_info: reactor_class_info
          )

          limit ||= arguments[:source].count
          arguments[:source].each_with_index do |element, index|
            break if index >= limit

            queue_map_element(map_id: map_id, element: element, index: index, arguments: arguments, context: context,
                              reactor_class_info: reactor_class_info, step_name: step_name)
          end

          queue_collector(map_id, context, step_name, arguments[:strict_ordering])
        end

        # rubocop:disable Metrics/ParameterLists
        def queue_map_element(map_id:, element:, index:, arguments:, context:, reactor_class_info:, step_name:)
          mapped_inputs = build_mapped_inputs(arguments[:argument_mappings] || {}, context, element)
          serialized_inputs = ContextSerializer.serialize_value(mapped_inputs)

          RubyReactor.configuration.async_router.perform_map_element_async(
            map_id: map_id, element_id: "#{map_id}:#{index}", index: index,
            serialized_inputs: serialized_inputs, reactor_class_info: reactor_class_info,
            strict_ordering: arguments[:strict_ordering], parent_context_id: context.context_id,
            parent_reactor_class_name: context.reactor_class.name, step_name: step_name.to_s,
            batch_size: arguments[:batch_size]
          )
        end
        # rubocop:enable Metrics/ParameterLists

        def queue_collector(map_id, context, step_name, strict_ordering)
          RubyReactor.configuration.async_router.perform_map_collection_async(
            parent_context_id: context.context_id, map_id: map_id,
            parent_reactor_class_name: context.reactor_class.name, step_name: step_name.to_s,
            strict_ordering: strict_ordering, timeout: 3600
          )
        end

        def queue_single_worker(map_id:, arguments:, context:, reactor_class_info:, step_name:)
          inputs = { source: arguments[:source], mappings: arguments[:argument_mappings] || {} }
          serialized_inputs = ContextSerializer.serialize_value(inputs)

          RubyReactor.configuration.async_router.perform_map_execution_async(
            map_id: map_id, serialized_inputs: serialized_inputs,
            reactor_class_info: reactor_class_info, strict_ordering: arguments[:strict_ordering],
            parent_context_id: context.context_id, parent_reactor_class_name: context.reactor_class.name,
            step_name: step_name.to_s
          )
        end
      end
    end
  end
end
