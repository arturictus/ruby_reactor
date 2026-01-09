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
            # Handle serialized template objects (Hashes from Sidekiq)
            source = ContextSerializer.deserialize_value(source) if source.is_a?(Hash) && source["_type"]

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

          process_results(results, arguments[:collect_block], arguments[:fail_fast])
        end

        def execute_inline_map(arguments, context)
          results = []
          fail_fast = arguments[:fail_fast].nil? || arguments[:fail_fast]

          arguments[:source].each do |element|
            result = execute_single_element(element, arguments, context)

            if fail_fast && result.failure?
              return result # Stop immediately on first failure
            end

            # When fail_fast is false, store Result objects; when true, store values
            results << (fail_fast ? result.value : result)
          end

          results
        end

        def execute_single_element(element, arguments, context)
          mapped_inputs = build_mapped_inputs(arguments[:argument_mappings] || {}, context, element)
          child_context = RubyReactor::Context.new(mapped_inputs, arguments[:mapped_reactor_class])

          link_contexts(child_context, context)

          map_id = "#{context.context_id}:#{context.current_step}"
          storage = RubyReactor.configuration.storage_adapter
          storage.store_map_element_context_id(map_id, child_context.context_id, context.reactor_class.name)

          # Set map metadata for failure handling
          child_context.map_metadata = {
            map_id: map_id,
            parent_reactor_class_name: context.reactor_class.name,
            index: nil # Inline map execution doesn't track index in metadata currently, but could
          }

          # Store reference in composed_contexts so the UI knows where to find elements
          context.composed_contexts[context.current_step] = {
            name: context.current_step,
            type: :map_ref,
            map_id: map_id,
            element_reactor_class: arguments[:mapped_reactor_class].name
          }

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

        def process_results(results, collect_block, fail_fast = true)
          if collect_block
            begin
              # Collect block receives Result objects when fail_fast is false, values when true
              RubyReactor::Success(collect_block.call(results))
            rescue StandardError => e
              RubyReactor::Failure(e)
            end
          elsif fail_fast
            # Default behavior when no collect block
            # Current behavior: results are already values
            RubyReactor::Success(results)
          else
            # New behavior: extract successful values only
            successes = results.select(&:success?).map(&:value)
            RubyReactor::Success(successes)
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
          context.map_operations[step_name.to_s] = map_id
          prepare_async_execution(context, map_id, arguments[:source].size)

          reactor_class_info = build_reactor_class_info(arguments[:mapped_reactor_class], context, step_name)

          # Initialize map operation metadata
          storage = RubyReactor.configuration.storage_adapter
          storage.initialize_map_operation(
            map_id, arguments[:source].size, context.reactor_class.name,
            strict_ordering: arguments[:strict_ordering], reactor_class_info: reactor_class_info
          )

          job_id = if arguments[:batch_size]
                     # Use new Dispatcher with Backpressure
                     RubyReactor::Map::Dispatcher.perform(
                       map_id: map_id,
                       parent_context_id: context.context_id,
                       parent_reactor_class_name: context.reactor_class.name,
                       source: arguments[:source],
                       batch_size: arguments[:batch_size],
                       step_name: step_name,
                       argument_mappings: arguments[:argument_mappings],
                       strict_ordering: arguments[:strict_ordering],
                       mapped_reactor_class: arguments[:mapped_reactor_class]
                     )
                     queue_collector(map_id, context, step_name, arguments[:strict_ordering])
                     "map:#{map_id}"
                   else
                     queue_single_worker(map_id: map_id, arguments: arguments, context: context,
                                         reactor_class_info: reactor_class_info, step_name: step_name)
                   end

          # Store reference in composed_contexts so the UI knows where to find elements
          context.composed_contexts[step_name.to_s] = {
            name: step_name.to_s,
            type: :map_ref,
            map_id: map_id,
            element_reactor_class: arguments[:mapped_reactor_class].name
          }

          RubyReactor::AsyncResult.new(
            job_id: job_id,
            intermediate_results: context.intermediate_results,
            execution_id: context.context_id
          )
        end

        def prepare_async_execution(context, map_id, count)
          storage = RubyReactor.configuration.storage_adapter
          serialized_context = ContextSerializer.serialize(context)
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

        # rubocop:disable Metrics/ParameterLists
        def queue_fan_out(map_id:, arguments:, context:, reactor_class_info:, step_name:, limit: nil)
          # rubocop:enable Metrics/ParameterLists
          storage = RubyReactor.configuration.storage_adapter
          storage.initialize_map_operation(
            map_id, arguments[:source].size, context.reactor_class.name,
            strict_ordering: arguments[:strict_ordering], reactor_class_info: reactor_class_info
          )

          limit ||= arguments[:source].size
          first_job_id = nil
          arguments[:source].each_with_index do |element, index|
            break if index >= limit

            job_id = queue_map_element(
              map_id: map_id, element: element, index: index, arguments: arguments,
              context: context, reactor_class_info: reactor_class_info, step_name: step_name
            )
            first_job_id ||= job_id
          end

          queue_collector(map_id, context, step_name, arguments[:strict_ordering])
          first_job_id
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
