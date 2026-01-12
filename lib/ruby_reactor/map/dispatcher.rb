# frozen_string_literal: true

module RubyReactor
  module Map
    class Dispatcher
      extend Helpers

      def self.perform(arguments)
        arguments = arguments.transform_keys(&:to_sym)
        parent_reactor_class_name = arguments[:parent_reactor_class_name]

        storage = RubyReactor.configuration.storage_adapter

        # Load parent context to resolve source
        parent_context = load_parent_context_from_storage(
          arguments[:parent_context_id],
          parent_reactor_class_name,
          storage
        )

        # Initialize metadata if first run
        initialize_map_metadata(arguments, storage) unless arguments[:continuation]

        # Resolve Source
        # We need to resolve the source to know what we are iterating.
        # Strict "Array Only" rule means we expect an Array-like object or we handle the
        # "Query Builder" result if user used it.
        source = resolve_source(arguments, parent_context)

        # Dispatch next batch
        dispatch_batch(source, arguments, parent_context, storage)
      end

      def self.initialize_map_metadata(arguments, storage)
        map_id = arguments[:map_id]
        reactor_class_name = arguments[:parent_reactor_class_name]

        # Reset or set initial offset. Use NX to act as a mutex/guard against duplicate initialization.
        storage.set_map_offset_if_not_exists(map_id, 0, reactor_class_name)
      end

      def self.resolve_source(arguments, context)
        # Arguments has :source which is a Template::Input or similar.
        # We need to resolve it against the context.
        source_template = arguments[:source]

        # Fallback: look up from step config if missing (e.g. called from ElementExecutor)
        if source_template.nil? && context
          step_name = arguments[:step_name]
          step_config = context.reactor_class.steps[step_name.to_sym]
          source_template = step_config.arguments[:source][:source]
        end

        # If source is packaged in arguments as a value (deserialized)
        return source_template if source_template.is_a?(Array)

        # Resolve template
        return source_template.resolve(context) if source_template.respond_to?(:resolve)

        source_template
      end

      def self.dispatch_batch(source, arguments, parent_context, storage)
        map_id = arguments[:map_id]
        reactor_class_name = arguments[:parent_reactor_class_name]

        # Fail Fast Check
        if arguments[:fail_fast]
          failed_context_id = storage.retrieve_map_failed_context_id(map_id, reactor_class_name)
          return if failed_context_id
        end

        batch_size = arguments[:batch_size] || source.size # Default to all if no batch_size (async=true only)

        # Atomically reserve a batch
        new_offset = storage.increment_map_offset(map_id, batch_size, reactor_class_name)
        current_offset = new_offset - batch_size

        batch_elements = if source.is_a?(Array)
                           source.slice(current_offset, batch_size) || []
                         elsif source.respond_to?(:offset) && source.respond_to?(:limit)
                           # Optimized for ActiveRecord and similar query builders
                           source.offset(current_offset).limit(batch_size).to_a
                         else
                           # Fallback for generic Enumerable
                           # This is inefficient for huge sets if not Array, but compliant
                           source.drop(current_offset).take(batch_size)
                         end

        return if batch_elements.empty?

        # Queue Jobs
        queue_options = {
          map_id: map_id,
          arguments: arguments,
          context: parent_context,
          reactor_class_info: resolve_reactor_class_info(arguments, parent_context),
          step_name: arguments[:step_name]
        }

        batch_elements.each_with_index do |element, i|
          absolute_index = current_offset + i
          queue_element_job(element, absolute_index, queue_options)
        end
      end

      def self.queue_element_job(element, index, options)
        arguments = options[:arguments]
        context = options[:context]

        # Resolve mappings
        mappings_template = arguments[:argument_mappings]

        # Fallback: look up from step config if missing (e.g. called from ElementExecutor)
        if mappings_template.nil? && context
          step_name = options[:step_name] || arguments[:step_name]
          step_config = context.reactor_class.steps[step_name.to_sym]
          mappings_template = step_config.arguments[:argument_mappings]
        end

        mappings = if mappings_template.respond_to?(:resolve)
                     mappings_template.resolve(context)
                   else
                     mappings_template || {}
                   end

        # Fix for weird structure observed in fallback (wrapped in :source -> Template::Value)
        if mappings.key?(:source) && mappings[:source].respond_to?(:value) && mappings[:source].value.is_a?(Hash)
          mappings = mappings[:source].value
        end

        mapped_inputs = build_element_inputs(mappings, context, element)
        serialized_inputs = ContextSerializer.serialize_value(mapped_inputs)

        RubyReactor.configuration.async_router.perform_map_element_async(
          map_id: options[:map_id],
          element_id: "#{options[:map_id]}:#{index}",
          index: index,
          serialized_inputs: serialized_inputs,
          reactor_class_info: options[:reactor_class_info],
          strict_ordering: arguments[:strict_ordering],
          parent_context_id: context.context_id,
          parent_reactor_class_name: context.reactor_class.name,
          step_name: options[:step_name].to_s,
          batch_size: arguments[:batch_size], # Passed to worker so it knows to trigger next batch?
          fail_fast: arguments[:fail_fast]
        )
      end

      def self.resolve_reactor_class_info(arguments, context)
        mapped_reactor_class = arguments[:mapped_reactor_class]
        step_name = arguments[:step_name]

        if mapped_reactor_class.respond_to?(:name)
          { "type" => "class", "name" => mapped_reactor_class.name }
        else
          { "type" => "inline", "parent" => context.reactor_class.name, "step" => step_name.to_s }
        end
      end
    end
  end
end
