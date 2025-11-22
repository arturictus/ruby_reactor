# frozen_string_literal: true

module RubyReactor
  module Step
    class MapStep
      include RubyReactor::Step

      def self.run(arguments, context)
        mapped_reactor_class = arguments[:mapped_reactor_class]
        mappings = arguments[:argument_mappings] || {}
        source = arguments[:source]
        _strict_ordering = arguments[:strict_ordering]
        collect_block = arguments[:collect_block]

        # If source is nil, we can't do anything
        return RubyReactor::Failure("Map source cannot be nil") if source.nil?

        # Check if we have a stored context for this step (from a previous retry)
        step_name = context.current_step

        # Initialize map state in context if not present
        context.map_operations ||= {}

        # Check if we should run async
        # Run async if:
        # 1. Explicitly configured as async
        # 2. Running in a context that requires async (e.g. inside a worker but not inline) - wait, if we are inside a worker, we usually run inline unless we want to fan out.
        #    Fan out is the main reason for async map.
        async = arguments[:async]

        return run_async(arguments, context, step_name) if async && !context.inline_async_execution

        # Inline execution
        results = []

        source.each_with_index do |element, _index|
          # Build inputs for the mapped reactor
          mapped_inputs = build_mapped_inputs(mappings, context, element)

          # Create new context for this element
          child_context = RubyReactor::Context.new(mapped_inputs, mapped_reactor_class)

          # Link contexts
          child_context.parent_context = context
          child_context.root_context = context.root_context || context
          child_context.test_mode = context.test_mode
          child_context.inline_async_execution = context.inline_async_execution

          # Execute the mapped reactor
          executor = RubyReactor::Executor.new(mapped_reactor_class, {}, child_context)
          executor.execute

          result = executor.result

          return result unless result.success?

          results << result.value

          # For now, fail fast on first error
        end

        # Apply collect block if provided
        if collect_block
          begin
            collected = collect_block.call(results)
            RubyReactor::Success(collected)
          rescue StandardError => e
            RubyReactor::Failure(e)
          end
        else
          RubyReactor::Success(results)
        end
      end

      def self.compensate(_reason, _arguments, _context)
        # TODO: Implement compensation for map steps
        RubyReactor.Success()
      end

      class << self
        private

        def build_mapped_inputs(mappings, context, element)
          inputs = {}

          mappings.each do |mapped_input_name, source|
            if source.is_a?(RubyReactor::Template::Element)
              # Handle element reference
              # For now assuming element() refers to the current map's element
              # In nested maps, we might need to check the name, but for now simple case
              value = resolve_element(source, element)
              inputs[mapped_input_name] = value
            else
              value = source.resolve(context)
              inputs[mapped_input_name] = value
            end
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

        def extract_path(value, path)
          if path.is_a?(Symbol) && value.respond_to?(:[])
            value[path]
          elsif path.is_a?(String)
            path.split(".").reduce(value) { |v, key| v&.send(:[], key) }
          elsif path.is_a?(Array)
            path.reduce(value) { |v, key| v&.send(:[], key) }
          elsif value.respond_to?(path)
            value.send(path)
          else
            nil
          end
        end

        def run_async(arguments, context, step_name)
          mapped_reactor_class = arguments[:mapped_reactor_class]
          mappings = arguments[:argument_mappings] || {}
          source = arguments[:source]
          strict_ordering = arguments[:strict_ordering]

          storage = RubyReactor.configuration.storage_adapter

          # Generate a unique map ID
          map_id = "#{context.context_id}:#{step_name}"

          # Store parent context so workers can retrieve it
          # We need to serialize the *current* state of the parent context
          # But we are in the middle of execution.
          # We should probably store it as "waiting" state.
          # The Executor will handle saving the state if we return RetryQueuedResult?
          # No, RetryQueuedResult assumes the job is already queued.
          # But here we are queuing *child* jobs.
          # The parent job needs to be suspended.

          # We need to manually store the parent context because the workers need it
          # to trigger the collector which will resume the parent.
          # The parent context should be stored with its current state.

          # IMPORTANT: We must ensure we don't overwrite the context if it's already stored?
          # Context ID is unique per execution.

          serialized_context = context.serialize_for_retry
          storage.store_context(context.context_id, serialized_context, context.reactor_class.name)

          # Set map counter
          count = source.count
          storage.set_map_counter(map_id, count, context.reactor_class.name)

          # Prepare reactor class info for workers
          reactor_class_info = if mapped_reactor_class.name
                                 { "type" => "class", "name" => mapped_reactor_class.name }
                               else
                                 # Inline reactor
                                 # We need to pass enough info to reconstruct it.
                                 # Since it's defined in the parent reactor's step config,
                                 # we can pass the parent class name and step name.
                                 {
                                   "type" => "inline",
                                   "parent" => context.reactor_class.name,
                                   "step" => step_name.to_s
                                 }
                               end

          # Queue workers
          source.each_with_index do |element, index|
            mapped_inputs = build_mapped_inputs(mappings, context, element)
            serialized_inputs = ContextSerializer.serialize_value(mapped_inputs)

            MapElementWorker.perform_async(
              map_id,
              index,
              serialized_inputs,
              reactor_class_info,
              strict_ordering,
              context.context_id,
              context.reactor_class.name,
              step_name.to_s
            )
          end

          # Return RetryQueuedResult to stop current execution
          # We use a special "async_map" reason or just standard RetryQueuedResult
          # The Executor will see this and stop.
          # We set next_retry_at to nil or far future?
          # Actually, we don't want it to retry automatically.
          # We want it to be resumed explicitly by MapCollectorWorker.

          RetryQueuedResult.new(step_name, 1, nil)
        end
      end
    end
  end
end
