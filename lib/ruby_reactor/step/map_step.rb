# frozen_string_literal: true

module RubyReactor
  class Step
    class MapStep < RubyReactor::Step
      include RubyReactor::Map::StepRollback

      # Seconds a rollback waits for an element's liveness lock. The last
      # element to settle triggers the collector before its own job releases
      # that lock, so a short wait covers the gap.
      ELEMENT_LOCK_WAIT = 2

      # Untyped, so no validation: declared only so `inputs.x` can read them.
      input :source
      input :mapped_reactor_class
      input :argument_mappings, optional: true
      input :strict_ordering, optional: true
      input :batch_size, optional: true
      input :collect_block, optional: true
      input :atomic, optional: true
      input :fan_out, optional: true
      input :undo_all_block, optional: true

      def run
        # Initialize map state in context if not present
        context.map_operations ||= {}
        # Dispatched already: the owner run resumed (009 R-03) — adopt the
        # settled outcome, never dispatch again (I-3).
        return adopt_dispatched_map(context.current_step) if dispatched_map_id(context.current_step)
        return RubyReactor::Failure("Map source cannot be nil") if inputs.source.nil?

        if fan_out?
          run_async(context.current_step)
        else
          run_inline
        end
      end

      # Compensating a failed map and undoing a completed one are the same work,
      # as for compose: replay the undo stack of every element that COMPLETED
      # (a failed element already rolled itself back; a halted or skipped one
      # did nothing to undo), newest-started first. Elements are found through
      # the index both modes write, so nothing per element lives in the parent
      # (008 R-02). Runs only once every element has settled (R-04), from the
      # execution that owns the map, so it is the elements' only writer.
      #
      # A map rolls back where it ran (009 R-01): a fan-out map one job per
      # started element, `batch_size` per throw, handing the run off until
      # they all report; an inline map in process, 100 elements per read.
      #
      # A map declaring `undo_all` rolls its completed elements back with one
      # call to that block instead (010 R-13).
      def compensate
        step_name = context.current_step
        map_id = "#{context.context_id}:#{step_name}"
        return bulk_rollback(map_id, step_name, undo_all_block) if undo_all_block

        dispatched_map_id(step_name) ? distributed_rollback(map_id, step_name) : inline_rollback(map_id, step_name)
      end

      alias undo compensate

      # An interrupted run is undone too: undo replays only each element's completed steps.
      def self.undoes_partial_run? = true

      # The undo record keeps no arguments: rollback reads the map's
      # declaration and records, never the resolved source (009 R-14).
      def self.rollback_arguments(_resolved) = {}

      class << self
        def build_mapped_inputs(mappings, context, element)
          built = {}

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
            built[mapped_input_name] = value
          end

          built
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
      end

      private

      # Read from the map step's static declaration, not from the undo record,
      # which a fan-out map leaves empty (R-03).
      def element_class
        context.reactor_class.steps[context.current_step].arguments[:mapped_reactor_class][:source].value
      end

      # The `undo_all` block, from the same static declaration (009 R-14): the
      # undo record carries no arguments.
      def undo_all_block
        context.reactor_class.steps[context.current_step].arguments[:undo_all_block]&.dig(:source)&.value
      end

      # Fans out anywhere except inside a map element: an element's result and
      # the map's completion counter are tracked by its own ElementExecutor job,
      # so a nested hand-off there would escape that tracking. A reactor worker
      # (`background`, collector resume, `async_reactor` child) fans out as the
      # caller would — the collector resumes the reactor in a worker either way.
      def fan_out?
        return false if context.map_metadata || context.root_context&.map_metadata

        inputs.fan_out
      end

      def atomic?
        inputs.atomic.nil? || inputs.atomic
      end

      def run_inline
        results = execute_inline_map
        return results if results.is_a?(RubyReactor::Failure) || results.is_a?(RubyReactor::Halt)

        collect_results(results)
      end

      def execute_inline_map
        results = []
        atomic = atomic?

        inputs.source.each_with_index do |element, index|
          result = execute_single_element(element, index)

          # An element-level Halt propagates as a run halt: stop immediately
          # rather than being collected as a (nil) value.
          return result if result.is_a?(RubyReactor::Halt)

          return result if atomic && result.failure? # Stop immediately on first failure

          # A non-atomic map collects Result objects; an atomic one, values.
          results << (atomic ? result.value : result)
        end

        results
      end

      def execute_single_element(element, index)
        mapped_inputs = self.class.build_mapped_inputs(inputs.argument_mappings || {}, context, element)
        child_context = RubyReactor::Context.new(mapped_inputs, inputs.mapped_reactor_class)

        link_contexts(child_context, context)

        map_id = "#{context.context_id}:#{context.current_step}"
        storage = RubyReactor.configuration.storage_adapter
        storage.store_map_element_context_id(map_id, child_context.context_id, context.reactor_class.name)

        # Set map metadata for failure handling
        child_context.map_metadata = {
          map_id: map_id,
          parent_reactor_class_name: context.reactor_class.name,
          index: index
        }

        # Store reference in composed_contexts so the UI knows where to find elements
        context.composed_contexts[context.current_step] = {
          name: context.current_step,
          type: :map_ref,
          map_id: map_id,
          element_reactor_class: inputs.mapped_reactor_class.name,
          started: index + 1
        }

        executor = RubyReactor::Executor.new(inputs.mapped_reactor_class, {}, child_context)
        executor.execute
        executor.result
      end

      def link_contexts(child_context, parent_context)
        child_context.parent_context = parent_context
        child_context.root_context = parent_context.root_context || parent_context
        child_context.inline_async_execution = parent_context.inline_async_execution
      end

      def run_async(step_name)
        map_id = "#{context.context_id}:#{step_name}"
        context.map_operations[step_name.to_s] = map_id
        prepare_async_execution(map_id, inputs.source.size)

        reactor_class_info = build_reactor_class_info(inputs.mapped_reactor_class, step_name)

        initialize_map_metadata(map_id, reactor_class_info)

        job_id = dispatch_async_map(map_id, reactor_class_info, step_name)

        # Store reference in composed_contexts so the UI knows where to find elements
        context.composed_contexts[step_name.to_s] = {
          name: step_name.to_s,
          type: :map_ref,
          map_id: map_id,
          element_reactor_class: inputs.mapped_reactor_class.name
        }

        # The owner's id: the run the caller holds, and the one the map's
        # completion resumes (a composed child's own id is internal).
        RubyReactor::DispatchResult.new(
          job_id: job_id,
          intermediate_results: context.intermediate_results,
          execution_id: owner_context.context_id
        )
      end

      def initialize_map_metadata(map_id, reactor_class_info)
        storage = RubyReactor.configuration.storage_adapter
        storage.initialize_map_operation(
          map_id, inputs.source.size, context.reactor_class.name,
          strict_ordering: inputs.strict_ordering, reactor_class_info: reactor_class_info,
          owner_context_id: owner_context.context_id,
          owner_reactor_class_name: RubyReactor.reactor_storage_name(owner_context.reactor_class),
          batch_size: effective_batch_size, atomic: atomic?,
          **map_recovery_metadata(context.current_step)
        )
      end

      # The top-level run: the one execution that writes the context tree, and
      # the one the map's completion resumes (009 R-03).
      def owner_context
        context.root_context || context
      end

      # Declared, or `Map::DEFAULT_BATCH_SIZE`: no throw enqueues more (R-10).
      def effective_batch_size
        inputs.batch_size || RubyReactor::Map::DEFAULT_BATCH_SIZE
      end

      def dispatched_map_id(step_name)
        Utils::FetchIndifferent.call(context.map_operations || {}, step_name)
      end

      # Re-entry of a dispatched map (S-1). Unsettled (an early or duplicate
      # resume): hand off again without dispatching. Settled: the failing
      # element's Failure for an atomic map, else the collected results. The
      # executor records either like any step result.
      def adopt_dispatched_map(step_name)
        map_id = dispatched_map_id(step_name)
        storage = RubyReactor.configuration.storage_adapter
        metadata = storage.retrieve_map_metadata(map_id, context.reactor_class.name)
        return RubyReactor::Failure("map :#{step_name} records expired before it settled") unless metadata

        total = metadata["count"].to_i
        if storage.count_map_results(map_id, context.reactor_class.name) < total
          return RubyReactor::DispatchResult.new(job_id: "map:#{map_id}", execution_id: owner_context.context_id,
                                                 intermediate_results: context.intermediate_results)
        end

        failed_id = storage.retrieve_map_failed_context_id(map_id, context.reactor_class.name)
        return adopt_element_failure(step_name, failed_id) if failed_id

        record_elements_started(step_name, total)
        collect_results(RubyReactor::Map::ResultEnumerator.new(map_id, context.reactor_class.name,
                                                               strict_ordering: inputs.strict_ordering))
      end

      # The element's own Failure, carrying its rollback failures: the executor
      # compensates the map (its completed elements) and rolls the run back.
      def adopt_element_failure(step_name, failed_id)
        data = RubyReactor.configuration.storage_adapter.retrieve_context(
          failed_id, RubyReactor.reactor_storage_name(element_class)
        )
        return RubyReactor::Failure("map :#{step_name} element failed; its context expired") unless data

        reason = RubyReactor::Context.deserialize_from_retry(data).failure_reason
        reason.is_a?(RubyReactor::Failure) ? reason : RubyReactor::Failure(reason)
      end

      # The collect block gets Result objects for a non-atomic map, values for
      # an atomic one; a raise is the map's failure.
      def collect_results(results)
        return RubyReactor::Success(results) unless inputs.collect_block

        RubyReactor::Success(inputs.collect_block.call(results))
      rescue RubyReactor::Error::Rescuable => e
        RubyReactor.configuration.logger.error("Map collect block raised: #{e.message}")
        RubyReactor::Failure(e)
      end

      # Every index of a completed map ran: record the count on the map's
      # reference, which outlives the element index, so a late rollback names
      # each element whose context expired.
      def record_elements_started(step_name, total)
        ref = Utils::FetchIndifferent.call(context.composed_contexts, step_name)
        ref[:started] = total if ref
      end

      # Recovery metadata for the map sweeper. When this map runs inside a map
      # element (context.map_metadata present), it is a NESTED map: its parent
      # holds the element's `map_element:` lock, not an `async:` lock (N1).
      def map_recovery_metadata(step_name)
        outer = context.map_metadata
        {
          parent_context_id: context.context_id,
          step_name: step_name.to_s,
          parent_is_map_element: !outer.nil?,
          outer_map_id: outer && (outer[:map_id] || outer["map_id"]),
          outer_index: outer && (outer[:index] || outer["index"])
        }
      end

      def dispatch_async_map(map_id, _reactor_class_info, step_name)
        # Every async map runs through the per-element Dispatcher path: each
        # element runs in its own worker, with the map counter/collector
        # tracking completion. This lets elements with async steps or async
        # retries hand off correctly instead of being forced to run
        # synchronously in a single worker. Without a declared batch_size, at
        # most `Map::DEFAULT_BATCH_SIZE` are enqueued per throw (009 R-10).
        batch_size = effective_batch_size

        RubyReactor::Map::Dispatcher.perform(
          map_id: map_id,
          parent_context_id: context.context_id,
          parent_reactor_class_name: context.reactor_class.name,
          source: inputs.source,
          batch_size: batch_size,
          step_name: step_name,
          argument_mappings: inputs.argument_mappings,
          strict_ordering: inputs.strict_ordering,
          mapped_reactor_class: inputs.mapped_reactor_class,
          atomic: atomic?
        )
        queue_collector(map_id, step_name, inputs.strict_ordering)
        "map:#{map_id}"
      end

      # Stores the context the Dispatcher reads the source from, and — for a
      # map inside a composed child — the owner's tree, which the map's
      # completion resumes (009 R-03): a fast resume must find it consistent,
      # as `handle_background_handoff` ensures for a `background` hand-off.
      def prepare_async_execution(map_id, count)
        storage = RubyReactor.configuration.storage_adapter
        middlewares = context.middlewares || Executor.middlewares_for(context.reactor_class)
        middlewares.on(:before_async_enqueue, context)
        serialized_context = ContextSerializer.serialize(context)
        storage.store_context(context.context_id, serialized_context, context.reactor_class.name)
        unless owner_context.equal?(context)
          storage.store_context(owner_context.context_id, ContextSerializer.serialize(owner_context),
                                RubyReactor.reactor_storage_name(owner_context.reactor_class))
        end
        storage.set_map_counter(map_id, count, context.reactor_class.name)
      end

      def build_reactor_class_info(mapped_reactor_class, step_name)
        if mapped_reactor_class.respond_to?(:name)
          { "type" => "class", "name" => mapped_reactor_class.name }
        else
          { "type" => "inline", "parent" => context.reactor_class.name, "step" => step_name.to_s }
        end
      end

      def queue_collector(map_id, step_name, strict_ordering)
        RubyReactor.configuration.async_router.perform_map_collection_async(
          parent_context_id: context.context_id, map_id: map_id,
          parent_reactor_class_name: context.reactor_class.name, step_name: step_name.to_s,
          strict_ordering: strict_ordering, timeout: 3600
        )
      end
    end
  end
end
