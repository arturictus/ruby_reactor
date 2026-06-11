# frozen_string_literal: true

module RubyReactor
  module Map
    class ElementExecutor
      extend Helpers

      def self.perform(arguments)
        arguments = arguments.transform_keys(&:to_sym)

        context = hydrate_or_create_context(arguments)
        # The element already runs inside its own background worker, so any async
        # steps (and async retries) must execute inline here rather than handing
        # off to a detached Worker that would escape map result/counter tracking.
        # This mirrors SidekiqWorkers::Worker, which sets the same flag.
        context.inline_async_execution = true

        storage = RubyReactor.configuration.storage_adapter
        storage.store_map_element_context_id(arguments[:map_id], context.context_id,
                                             arguments[:parent_reactor_class_name])

        return if check_fail_fast?(arguments, storage)

        executor = Executor.new(context.reactor_class, {}, context)
        arguments[:serialized_context] ? executor.resume_execution : executor.execute

        result = executor.result

        # An async retry requeued this element as a fresh MapElementWorker job, so
        # it is not finished yet. Do not store a result, decrement the completion
        # counter, or trigger the next batch — the requeued job will do that when
        # the element ultimately succeeds or exhausts its retries.
        return if result.is_a?(RetryQueuedResult)

        handle_result(result, arguments, context, storage, executor)
        finalize_execution(arguments, storage)
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

      # rubocop:disable Style/IdenticalConditionalBranches
      def self.hydrate_or_create_context(arguments)
        if arguments[:serialized_context]
          context = ContextSerializer.deserialize(arguments[:serialized_context])
          context.map_metadata = arguments

          if context.inputs.empty? && arguments[:serialized_inputs]
            context.inputs = ContextSerializer.deserialize_value(arguments[:serialized_inputs])
          end
          context
        else
          inputs = ContextSerializer.deserialize_value(arguments[:serialized_inputs])
          reactor_class = resolve_reactor_class(arguments[:reactor_class_info])

          context = Context.new(inputs, reactor_class)
          context.parent_context_id = arguments[:parent_context_id]
          context.map_metadata = arguments
          context
        end
      end
      # rubocop:enable Style/IdenticalConditionalBranches

      def self.check_fail_fast?(arguments, storage)
        return false unless arguments[:fail_fast]

        map_id = arguments[:map_id]
        parent_reactor_class_name = arguments[:parent_reactor_class_name]

        failed_context_id = storage.retrieve_map_failed_context_id(map_id, parent_reactor_class_name)
        return false unless failed_context_id

        # Skip execution
        finalize_execution(arguments, storage)
        true
      end

      def self.handle_result(result, arguments, context, storage, executor)
        return if result.is_a?(RetryQueuedResult)

        map_id = arguments[:map_id]
        index = arguments[:index]
        parent_class = arguments[:parent_reactor_class_name] # Using short name for variable

        if result.success?
          storage.store_map_result(map_id, index, ContextSerializer.serialize_value(result.value),
                                   parent_class, strict_ordering: arguments[:strict_ordering])
        else
          executor.undo_all
          storage.store_map_result(map_id, index, { _error: result.error }, parent_class,
                                   strict_ordering: arguments[:strict_ordering])

          if arguments[:fail_fast]
            storage.store_map_failed_context_id(map_id, context.context_id, parent_class)
            # FAST FAIL: Trigger Collector immediately to cancel/fail the map execution
            RubyReactor.configuration.async_router.perform_map_collection_async(
              parent_context_id: arguments[:parent_context_id],
              map_id: map_id,
              parent_reactor_class_name: parent_class,
              step_name: arguments[:step_name],
              strict_ordering: arguments[:strict_ordering],
              timeout: 3600
            )
          end
        end
      end

      def self.finalize_execution(arguments, storage)
        map_id = arguments[:map_id]
        parent_class = arguments[:parent_reactor_class_name]

        new_count = storage.decrement_map_counter(map_id, parent_class)
        trigger_next_batch_if_needed(arguments, arguments[:index], arguments[:batch_size])

        return unless new_count.zero?

        RubyReactor.configuration.async_router.perform_map_collection_async(
          parent_context_id: arguments[:parent_context_id],
          map_id: map_id,
          parent_reactor_class_name: parent_class,
          step_name: arguments[:step_name],
          strict_ordering: arguments[:strict_ordering],
          timeout: 3600
        )
      end

      def self.trigger_next_batch_if_needed(arguments, index, batch_size)
        return unless batch_size && ((index + 1) % batch_size).zero?

        # Trigger Dispatcher for next batch
        next_batch_args = arguments.dup
        # Ensure we don't carry over temporary execution flags if any
        next_batch_args[:continuation] = true
        RubyReactor::Map::Dispatcher.perform(next_batch_args)
      end

      private_class_method :load_parent_context, :trigger_next_batch_if_needed
    end
  end
end
