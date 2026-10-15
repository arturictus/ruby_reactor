# frozen_string_literal: true

module RubyReactor
  # Where a unit's jobs run (011). The one place a queue is resolved: a unit
  # uses its own declaration, else the queue of the unit that contains it,
  # else the global `queue_name` (FR-005, research R-02, data-model §2).
  # Every answer is a String.
  module Queues
    module_function

    # The global default, read when asked so a late `configure` still counts.
    def global
      RubyReactor.configuration.queue_name.to_s
    end

    # The queue of the units a context runs: its reactor's declaration, else
    # its container's (a linked composed child or inline map element), else
    # the container's queue recorded at dispatch (an `async_reactor` child, a
    # fan-out element), else the global one.
    def of_context(ctx)
      return global unless ctx

      declared(ctx.reactor_class) ||
        (ctx.parent_context ? of_context(ctx.parent_context) : inherited_queue(ctx)) ||
        global
    end

    # The queue of the job that runs this graph node. A plain step, a compose
    # and an inline map run their own work and may declare another queue;
    # every other node dispatches or pauses from its container's job.
    def node_queue(step_config, ctx)
      own_queue(step_config) || of_context(ctx)
    end

    # The queue of a dispatched unit's own jobs: an `async_step`, an
    # `async_reactor` child, a fan-out map's elements.
    def dispatch_queue(step_config, ctx)
      declared =
        case kind(step_config)
        when :async_step then step_config.queue
        when :async_reactor then declared(argument(step_config, :async_reactor_class))
        when :inline_map, :fan_out_map then declared(argument(step_config, :mapped_reactor_class))
        end
      declared || of_context(ctx)
    end

    # A fan-out map's queues (011 FR-015): its elements' (the element reactor's,
    # else this map's container's), and the collector's that resumes the
    # owner (the owner's current job, else the owner's own queue).
    def map_queues(element_class, ctx)
      owner = ctx.root_context || ctx
      { queue: declared(element_class) || of_context(ctx), owner_queue: current(ctx) || of_context(owner) }
    end

    # The queue of the job executing this context tree; nil in the calling
    # process, where no hop ever happens (FR-006).
    def current(ctx)
      ctx && (ctx.root_context || ctx).current_queue
    end

    # The queue a run in a job must hop to before running this node, or nil
    # (011 R-05). Never in the calling process, never inside a map element (a
    # hop there is rejected at definition time, R-09), and never for a compose
    # whose child already started: the child's own steps decide (H-9).
    def forward_hop_target(step_config, ctx)
      current = current(ctx)
      return nil if current.nil? || within_map_element?(ctx)
      return nil if kind(step_config) == :compose && child_context(ctx, step_config.name)

      target = node_queue(step_config, ctx)
      target == current ? nil : target
    end

    # The queue a rollback in a job must hop to before undoing this entry, or
    # nil (011 R-07). A compose whose child's own rollback already started is
    # finished where it is: the child's entries hop for themselves (H-9).
    def rollback_hop_target(step_config, ctx)
      current = current(ctx)
      return nil if current.nil? || within_map_element?(ctx)
      return nil if kind(step_config) == :compose && child_context(ctx, step_config.name)&.rollback

      target = node_queue(step_config, ctx)
      target == current ? nil : target
    end

    # A dispatch of the run to `queue` is already on its way: a duplicate job
    # that would hop there only stops (011 R-05 dedupe).
    def dispatch_pending?(ctx, queue)
      root = ctx.root_context || ctx
      record = RubyReactor.configuration.storage_adapter.retrieve_run_dispatch(
        root.context_id, RubyReactor.reactor_storage_name(root.reactor_class)
      )
      !record.nil? && record["queue"] == queue && !record["since"].to_s.empty?
    end

    # `bank_deposit.two`: the node's name with the compose steps above it.
    def path(ctx, name)
      names = [name]
      while (ctx = ctx.parent_context)
        names.unshift(ctx.current_step) if ctx.current_step
      end
      names.join(".")
    end

    # Keyword arguments for a router call: none for the global queue, so a run
    # with no declarations enqueues exactly what it did before (FR-024).
    def kwargs(queue)
      queue.nil? || queue.to_s == global ? {} : { queue: queue.to_s }
    end

    # Every dispatch of a run's Worker (data-model §3.1): the queue is the given
    # one, else the run's dispatch record (where it last went), else its
    # reactor's own. The record is written BEFORE the job exists (H-1), so a
    # crash in between leaves a waiting run the sweeper re-enqueues.
    # rubocop:disable Metrics/ParameterLists
    def enqueue_run(context_id, reactor_class_name, queue: nil, delay: nil, snooze_count: nil,
                    intermediate_results: {}, router: nil)
      # rubocop:enable Metrics/ParameterLists
      storage = RubyReactor.configuration.storage_adapter
      queue = (queue || storage.retrieve_run_dispatch(context_id, reactor_class_name)&.dig("queue") ||
               declared(Context.resolve_reactor_class(reactor_class_name)) || global).to_s
      storage.store_run_dispatch(context_id, reactor_class_name, queue)

      router ||= RubyReactor.configuration.async_router
      # Only what differs from the router's defaults, so a run on the global
      # queue calls it exactly as before (custom routers, FR-024).
      options = kwargs(queue)
      options[:intermediate_results] = intermediate_results if intermediate_results&.any?
      return router.perform_async(context_id, reactor_class_name, **options) unless delay

      options[:snooze_count] = snooze_count if options[:queue] && snooze_count
      router.perform_in(delay, context_id, reactor_class_name, **options)
    end

    # Rejects, before the first run, the configurations in which a hop could
    # not keep every guarantee (011 R-09, FR-019): never run them weaker.
    #
    # 1. Inside a map element every unit runs on the element's queue: a
    #    waiting fan-out element is re-dispatched from the start by the map
    #    sweeper, and an inline element re-runs with its map step.
    # 2. A `with_ordered_lock` run never hops: nothing keeps its position alive
    #    while it waits in a queue, so a successor could pass it.
    def validate_definition!(reactor_class)
      reactor_class.steps.each_value do |config|
        next unless %i[inline_map fan_out_map].include?(kind(config))

        element = argument(config, :mapped_reactor_class)
        each_hop_unit(element, maps: true) do |unit, queue, path|
          next if queue == declared(element)

          raise Error::ValidationError, element_hop_message(reactor_class, config.name, element, unit, queue, path)
        end
      end
      validate_ordered_lock!(reactor_class)
    end

    def validate_ordered_lock!(reactor_class)
      return unless reactor_class.respond_to?(:ordered_lock_config) && reactor_class.ordered_lock_config

      allowed = declared(reactor_class) || global
      each_hop_unit(reactor_class, maps: false) do |unit, queue, path|
        next if queue == allowed

        raise Error::ValidationError,
              "#{reactor_class.name} declares `with_ordered_lock`, and #{describe(unit, path)} would hop to queue " \
              ":#{queue}. A run waiting in a queue cannot keep its ordered-lock position alive, so a successor " \
              "could pass it. Keep every unit on #{reactor_class.name}'s queue."
      end
    end

    # Yields each unit of `klass`'s tree that runs its own work — a plain step,
    # a compose, a map (each map runs inline inside an element) — and declares
    # a queue, with its path. Recurses through compose, and through maps when
    # `maps` (a map element's tree); an ordered run's fan-out maps dispatch.
    def each_hop_unit(klass, maps:, path: [], seen: {}, &block)
      return if seen[klass] || !klass.respond_to?(:steps)

      seen[klass] = true
      klass.steps.each_value do |config|
        unit_kind = kind(config)
        next if %i[async_step async_reactor interrupt].include?(unit_kind) || (unit_kind == :fan_out_map && !maps)

        child = argument(config, unit_kind == :compose ? :composed_reactor_class : :mapped_reactor_class)
        queue = unit_kind == :step ? config.queue : declared(child)
        unit_path = path + [config.name]
        yield config, queue, unit_path if queue
        each_hop_unit(child, maps: maps, path: unit_path, seen: seen, &block) if unit_kind != :step
      end
    end

    def element_hop_message(owner, map_name, element, unit, queue, path) # rubocop:disable Metrics/ParameterLists
      runs_on = declared(element) ? ":#{declared(element)}" : "its container's queue"
      "#{owner.name} map :#{map_name}: #{describe(unit, path)} runs on queue :#{queue} inside element reactor " \
        "#{element.name}, which runs on #{runs_on}. A map element cannot hop queues: an element waiting in a " \
        "queue is re-dispatched from the start, and an inline element re-runs with its map. Declare the same " \
        "queue on #{element.name} and the unit, or drop the unit's `queue`."
    end

    def describe(unit, path)
      label = { compose: "compose", inline_map: "map", fan_out_map: "map" }.fetch(kind(unit), "step")
      "#{label} :#{path.join(".")}"
    end

    # A Worker took the run (011): its job's queue becomes the tree's current
    # queue, and the run no longer waits there.
    def picked_up(ctx, context_id, reactor_class_name, queue)
      job_queue = (queue || global).to_s
      ctx.current_queue = job_queue
      RubyReactor.configuration.storage_adapter.clear_run_dispatch_wait(context_id, reactor_class_name, job_queue)
    end

    # The run is saved, its holds parked, and the Worker still holds its lock:
    # the continuation goes to the hop's queue (011 H-1, H-2). A duplicate
    # whose target already has a job on its way only stops.
    def hop!(context_id, reactor_class_name, ctx, hop)
      fields = { event: "ruby_reactor.queue.hop", reactor: reactor_class_name, execution_id: context_id,
                 step: hop.step.to_s, from: current(ctx), to: hop.queue, direction: "forward" }
      fields[:deduped] = true if hop.deduped?
      RubyReactor.configuration.logger.info(fields.map { |k, v| "#{k}=#{v.inspect}" }.join(" "))
      enqueue_run(context_id, reactor_class_name, queue: hop.queue) unless hop.deduped?
    end

    # A Worker snoozing stays on its job's queue (011): through the router
    # when that queue is not the global one (the dispatch); otherwise the run
    # is only recorded as waiting on the global queue, and the Worker
    # re-enqueues itself as it always did (nil).
    def snooze_run(context_id, reactor_class_name, queue, delay, snooze_count)
      if queue && kwargs(queue).any?
        return enqueue_run(context_id, reactor_class_name, queue: queue, delay: delay, snooze_count: snooze_count)
      end

      RubyReactor.configuration.storage_adapter.store_run_dispatch(context_id, reactor_class_name, global)
      nil
    end

    # Whether the reactor, a plain step, or (recursively) a compose or map
    # child declares a queue — the units a rollback undoes. Async units are
    # never undone, so they do not count.
    def declares_any?(reactor_class, seen = {})
      return false if seen[reactor_class]

      seen[reactor_class] = true
      return true if declared(reactor_class)

      reactor_class.steps.each_value.any? do |config|
        case kind(config)
        when :step then !config.queue.nil?
        when :compose then tree_declares?(argument(config, :composed_reactor_class), seen)
        when :inline_map, :fan_out_map then tree_declares?(argument(config, :mapped_reactor_class), seen)
        else false
        end
      end
    end

    def tree_declares?(reactor_class, seen)
      reactor_class.respond_to?(:steps) && declares_any?(reactor_class, seen)
    end

    def own_queue(step_config)
      case kind(step_config)
      when :step then step_config.queue
      when :compose then declared(argument(step_config, :composed_reactor_class))
      when :inline_map then declared(argument(step_config, :mapped_reactor_class))
      end
    end

    def kind(step_config)
      return :interrupt if step_config.respond_to?(:interrupt?) && step_config.interrupt?
      return :async_step if step_config.async_dispatch == :step
      return :async_reactor if step_config.async_dispatch == :reactor
      return :compose if step_config.impl == Step::ComposeStep
      return (argument(step_config, :fan_out) ? :fan_out_map : :inline_map) if step_config.impl == Step::MapStep

      :step
    end

    # A compose/map/async_reactor's static argument (its child class, its
    # fan-out flag), as `MapStep#element_class` reads it.
    def argument(step_config, key)
      source = step_config.arguments.dig(key, :source)
      source.value if source.respond_to?(:value)
    end

    def declared(klass)
      klass.declared_queue if klass.respond_to?(:declared_queue)
    end

    def child_context(ctx, name)
      entry = ctx.composed_contexts[name] || ctx.composed_contexts[name.to_s]
      child = entry.is_a?(Hash) && (entry[:context] || entry["context"])
      child if child.is_a?(Context)
    end

    def within_map_element?(ctx)
      ctx = ctx.parent_context until ctx.nil? || ctx.map_metadata
      !ctx.nil?
    end

    def inherited_queue(ctx)
      value = ctx.private_data["inherited_queue"] || ctx.private_data[:inherited_queue]
      value&.to_s
    end

    private_class_method :tree_declares?, :own_queue, :kind, :argument, :declared, :child_context,
                         :within_map_element?, :inherited_queue, :validate_ordered_lock!, :each_hop_unit,
                         :element_hop_message, :describe
  end
end
