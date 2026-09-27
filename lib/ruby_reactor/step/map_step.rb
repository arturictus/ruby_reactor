# frozen_string_literal: true

module RubyReactor
  class Step
    class MapStep < RubyReactor::Step
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
      input :fail_fast, optional: true
      input :fan_out, optional: true

      def run
        return RubyReactor::Failure("Map source cannot be nil") if inputs.source.nil?

        # Initialize map state in context if not present
        context.map_operations ||= {}

        if fan_out?
          run_async(context.current_step)
        else
          run_inline
        end
      end

      # Compensating a failed map and undoing a completed one are the same work,
      # as for compose: replay the undo stack of every element that COMPLETED
      # (a failed element already rolled itself back; a halted or skipped one
      # did nothing to undo), highest index first. Elements are found through
      # the index both modes write, so nothing per element lives in the parent
      # (008 R-02). Runs only once every element has settled (R-04), from the
      # execution that owns the map, so it is the elements' only writer.
      #
      # ponytail: serial, in the process that detected the failure, so rollback
      # time is linear in the number of completed elements. Fan the rollback
      # out per element if that ever outgrows one job.
      def compensate
        step_name = context.current_step
        map_id = "#{context.context_id}:#{step_name}"
        failures = []

        completed_elements(map_id, failures).each do |index, element_context|
          tag = { map_step: step_name.to_sym, element_index: index }
          failures.concat(rollback_element(map_id, index, element_context).map { |entry| entry.merge(tag) })
        end

        return RubyReactor.Success() if failures.empty?

        RubyReactor.Failure("map :#{step_name} rollback incomplete", rollback_failures: failures)
      end

      alias undo compensate

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

      # `[[index, context], ...]` for every completed element, highest index
      # first. An indexed element whose row is gone (expired past
      # `context_ttl`) is reported, never skipped silently; its index lived in
      # that row.
      def completed_elements(map_id, failures)
        storage = RubyReactor.configuration.storage_adapter
        storage_name = RubyReactor.reactor_storage_name(element_class)
        # A parked or retried fan-out element registers its id again.
        ids = storage.retrieve_map_element_context_ids(map_id, context.reactor_class.name).uniq

        elements = ids.filter_map do |id|
          data = storage.retrieve_context(id, storage_name)
          unless data
            failures << element_unavailable(id)
            next
          end

          element_context = RubyReactor::Context.deserialize_from_retry(data)
          next unless element_context.status.to_s == "completed"

          meta = element_context.map_metadata || {}
          [(meta[:index] || meta["index"]).to_i, element_context]
        end
        elements.sort_by { |index, _| -index }
      end

      def element_unavailable(id)
        step_name = context.current_step.to_sym
        { step: step_name, kind: :undo, key: nil, reason: :context_unavailable, map_step: step_name,
          element_index: nil, message: "element context #{id} expired before rollback" }
      end

      # The element's own undo stack, replayed as `ComposeStep` replays its
      # child's, under the element's liveness lock: a held lock after the map
      # settled is a live duplicate delivery, which is left alone and reported.
      def rollback_element(map_id, index, element_context)
        lock = acquire_element_lock(map_id, index)
        return [element_in_flight(index)] if lock == :held

        executor = RubyReactor::Executor.new(element_class, {}, element_context)
        executor.undo_all
        executor.save_context
        executor.compensation_manager.rollback_failures
      ensure
        lock.release if lock.respond_to?(:release)
      end

      def acquire_element_lock(map_id, index)
        return nil if RubyReactor::Map::ElementExecutor.inline_testing_mode?

        config = RubyReactor.configuration
        lock = RubyReactor::Lock.new("map_element:#{map_id}:#{index}",
                                     owner: SecureRandom.uuid, ttl: config.context_lock_ttl, wait: ELEMENT_LOCK_WAIT)
        lock.acquire
        lock
      rescue RubyReactor::Lock::AcquisitionError
        :held
      end

      def element_in_flight(index)
        { step: context.current_step.to_sym, kind: :undo, key: nil, reason: :element_in_flight,
          message: "map element #{index} was still running at rollback time" }
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

      def run_inline
        results = execute_inline_map
        return results if results.is_a?(RubyReactor::Failure) || results.is_a?(RubyReactor::Halt)

        process_results(results, inputs.collect_block, inputs.fail_fast)
      end

      def execute_inline_map
        results = []
        fail_fast = inputs.fail_fast.nil? || inputs.fail_fast

        inputs.source.each_with_index do |element, index|
          result = execute_single_element(element, index)

          # An element-level Halt propagates as a run halt: stop immediately
          # rather than being collected as a (nil) value.
          return result if result.is_a?(RubyReactor::Halt)

          if fail_fast && result.failure?
            return result # Stop immediately on first failure
          end

          # When fail_fast is false, store Result objects; when true, store values
          results << (fail_fast ? result.value : result)
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
          element_reactor_class: inputs.mapped_reactor_class.name
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

      def process_results(results, collect_block, _fail_fast = true)
        if collect_block
          begin
            # Collect block receives Result objects when fail_fast is false, values when true
            return RubyReactor::Success(collect_block.call(results))
          rescue RubyReactor::Error::Rescuable => e
            return RubyReactor::Failure(e)
          end
        end

        # Simplified: both branches returned Success(results)
        RubyReactor::Success(results)
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

        RubyReactor::DispatchResult.new(
          job_id: job_id,
          intermediate_results: context.intermediate_results,
          execution_id: context.context_id
        )
      end

      def initialize_map_metadata(map_id, reactor_class_info)
        storage = RubyReactor.configuration.storage_adapter
        storage.initialize_map_operation(
          map_id, inputs.source.size, context.reactor_class.name,
          strict_ordering: inputs.strict_ordering, reactor_class_info: reactor_class_info,
          **map_recovery_metadata(context.current_step)
        )
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
        # Every async map runs through the per-element Dispatcher path. When no
        # batch_size is given we default to the full source size (one fan-out
        # batch), so there is a single execution path: each element runs in its
        # own worker, with the map counter/collector tracking completion. This
        # lets elements with async steps or async retries hand off correctly
        # instead of being forced to run synchronously in a single worker.
        batch_size = inputs.batch_size || inputs.source.size

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
          fail_fast: inputs.fail_fast.nil? || inputs.fail_fast
        )
        queue_collector(map_id, step_name, inputs.strict_ordering)
        "map:#{map_id}"
      end

      def prepare_async_execution(map_id, count)
        storage = RubyReactor.configuration.storage_adapter
        middlewares = context.middlewares || Executor.middlewares_for(context.reactor_class)
        middlewares.on(:before_async_enqueue, context)
        serialized_context = ContextSerializer.serialize(context)
        storage.store_context(context.context_id, serialized_context, context.reactor_class.name)
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
