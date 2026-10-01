# frozen_string_literal: true

module RubyReactor
  module Map
    class Dispatcher
      extend Helpers

      def self.perform(arguments)
        arguments = Helpers.normalize_arguments(arguments)
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

        # An atomic map stops dispatching at its first failure.
        if arguments[:atomic] && storage.retrieve_map_failed_context_id(map_id, reactor_class_name)
          return settle_undispatched(arguments, storage)
        end

        batch_size = arguments[:batch_size] || RubyReactor::Map::DEFAULT_BATCH_SIZE

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

      # An atomic map stopped dispatching: claim every index not dispatched
      # yet (one offset bump, so a later dispatcher claims none), settle each
      # with a `_skipped` slot, count them down, and trigger the collector if
      # that settled the map. Without this those indices never settle, so the
      # failure would never be applied (R-04) and the map sweeper would keep
      # re-dispatching them.
      def self.settle_undispatched(arguments, storage)
        map_id = arguments[:map_id]
        reactor_class_name = arguments[:parent_reactor_class_name]
        total = storage.retrieve_map_metadata(map_id, reactor_class_name)&.fetch("count", 0).to_i
        new_offset = storage.increment_map_offset(map_id, total, reactor_class_name)
        claimed = (new_offset - total)...[new_offset, total].min
        return if claimed.none?

        claimed.each do |index|
          storage.store_map_result(map_id, index, { "_skipped" => true }, reactor_class_name,
                                   strict_ordering: arguments[:strict_ordering])
        end
        return unless storage.decrement_map_counter_by(map_id, claimed.size, reactor_class_name) <= 0

        RubyReactor.configuration.async_router.perform_map_collection_async(
          parent_context_id: arguments[:parent_context_id], map_id: map_id,
          parent_reactor_class_name: reactor_class_name, step_name: arguments[:step_name].to_s,
          strict_ordering: arguments[:strict_ordering], timeout: 3600
        )
      end

      # Re-dispatch a SPECIFIC index whose result slot is missing (Phase 5c, used
      # by the map sweeper). Index-driven rather than offset-driven: resolve the
      # source from the stored parent context and pick source[index]. Idempotent
      # because store_map_result HSETs by index — a re-run overwrites slot `index`,
      # never duplicates.
      def self.requeue_index(map_meta, index)
        storage = RubyReactor.configuration.storage_adapter
        parent_class_name = map_meta["parent_reactor_class_name"]
        parent_context = load_parent_context_from_storage(map_meta["parent_context_id"], parent_class_name, storage)

        arguments = {
          map_id: map_meta["map_id"],
          step_name: map_meta["step_name"],
          strict_ordering: map_meta["strict_ordering"],
          parent_context_id: map_meta["parent_context_id"],
          parent_reactor_class_name: parent_class_name,
          atomic: map_meta["atomic"],
          batch_size: map_meta["batch_size"]
        }

        source = resolve_source(arguments, parent_context)
        element = element_at(source, index)

        queue_element_job(element, index, {
                            map_id: map_meta["map_id"],
                            arguments: arguments,
                            context: parent_context,
                            reactor_class_info: map_meta["reactor_class_info"],
                            step_name: map_meta["step_name"]
                          })
      end

      def self.element_at(source, index)
        if source.is_a?(Array)
          source[index]
        elsif source.respond_to?(:offset) && source.respond_to?(:limit)
          source.offset(index).limit(1).to_a.first
        else
          source.drop(index).first
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
          atomic: arguments[:atomic]
        )
      end

      # One throw of a map's distributed rollback (009 R-02, R-06): claim the
      # next `batch_size` positions of the element-context index, counted from
      # its tail, and enqueue one rollback job per position. The job at the
      # last position of a throw claims the next one, as forward.
      def self.dispatch_rollback_batch(map_id:, parent_reactor_class_name:)
        storage = RubyReactor.configuration.storage_adapter
        meta = storage.retrieve_map_rollback_metadata(map_id, parent_reactor_class_name)
        return 0 unless meta

        positions = storage.claim_map_rollback_positions(map_id, parent_reactor_class_name, meta["batch_size"].to_i)
        return 0 if positions.none?

        ids = storage.retrieve_map_element_context_ids_from_tail(map_id, parent_reactor_class_name, positions.first,
                                                                 positions.size, total: meta["total"].to_i)
        positions.each_with_index do |position, i|
          queue_rollback_job(meta, map_id, parent_reactor_class_name, position, ids[i])
        end
        positions.size
      end

      # rubocop:disable Metrics/ParameterLists
      def self.queue_rollback_job(meta, map_id, parent_reactor_class_name, position, element_context_id, attempt: 0)
        RubyReactor.configuration.async_router.perform_map_element_rollback_async(
          map_id: map_id, position: position, element_context_id: element_context_id,
          reactor_class_info: meta["reactor_class_info"], parent_reactor_class_name: parent_reactor_class_name,
          step_name: meta["step_name"], batch_size: meta["batch_size"], owner_context_id: meta["owner_context_id"],
          owner_reactor_class_name: meta["owner_reactor_class_name"], attempt: attempt
        )
      end
      # rubocop:enable Metrics/ParameterLists

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
