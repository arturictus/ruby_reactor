# frozen_string_literal: true

module RubyReactor
  module Dsl
    # The three ways a reactor sends work out of the calling process, kept
    # together because they are one design decision seen from three distances:
    #
    #   background     — the rest of THIS reactor moves to a worker
    #                    (`all: true` — EVERYTHING, incl. input validation)
    #   async_step     — ONE step's work becomes its own job
    #   async_reactor  — a whole nested reactor runs independently
    #
    # Mixed into `Dsl::Reactor::ClassMethods`.
    module AsyncMacros
      # The single, unambiguous cut point between what runs in
      # the calling process and what is handed to a worker. Replaces the
      # per-step `async` flag, where only the first flagged step ever took
      # effect and the rest were silently ignored, and the whole-reactor
      # `async true` flag, which named the same idea with a different word.
      #
      #   background after:  :second   # :second is the LAST step to run here
      #   background before: :third    # :third is the FIRST step in the worker
      #   background all: true         # the ENTIRE reactor runs in the worker,
      #                                 # including input validation
      #
      # `after:`/`before:` name one cut point from opposite sides — identical
      # in a linear chain, different in a DAG, where each pins the step it
      # names. `all:` names no step: there is nothing left to pin, everything
      # moves. Triggering is keyed to REACHING the named step (or, for `all:`,
      # to the run starting at all), not to where this declaration sits in
      # the class body.
      def background(after: nil, before: nil, all: false)
        point = validate_background_declaration!(after, before, all)

        @background_handoff = point
      end

      # The normalized `{ mode:, step: }` pair — one reader, never a one-sided
      # `background_after`, so no consumer can be accidentally implemented for
      # `after:` only. `step` is `nil` when `mode` is `:all`.
      def background_handoff
        @background_handoff
      end

      # True only for the whole-reactor hand-off (`background all: true`) —
      # the entire run, including input validation, happens in a worker.
      def async?
        background_handoff&.fetch(:mode, nil) == :all
      end

      def validate_background_declaration!(after, before, all)
        given = [after, before, all].count { |v| v }
        if given > 1
          raise RubyReactor::Error::ValidationError,
                "`background` takes exactly one of `after:`, `before:`, or `all:`, got more than one " \
                "(after: #{after.inspect}, before: #{before.inspect}, all: #{all.inspect}). Each names a " \
                "different hand-off shape: `after: :x` / `before: :x` pin a cut point around step :x; " \
                "`all: true` sends the whole reactor, including input validation."
        end

        if given.zero?
          raise RubyReactor::Error::ValidationError,
                "`background` requires one of `after: :step_name` (that step is the last to run in the " \
                "calling process), `before: :step_name` (that step is the first to run in the worker), or " \
                "`all: true` (the entire reactor, including input validation, runs in the worker)."
        end

        point = if all
                  { mode: :all, step: nil }
                else
                  { mode: after ? :after : :before, step: (after || before).to_sym }
                end

        # Re-declaring the SAME point is a no-op — a class body can be
        # evaluated twice (Rails reloading, a spec reopening a fixture class)
        # and that must not be an error. A DIFFERENT second point is the real
        # footgun `background` exists to remove.
        if background_handoff && background_handoff != point
          raise RubyReactor::Error::ValidationError,
                "#{name || "This reactor"} already declares `background " \
                "#{describe_handoff_point(background_handoff)}` and cannot also declare `background " \
                "#{describe_handoff_point(point)}`. A reactor has exactly one hand-off point — a second " \
                "would reintroduce the ambiguity `background` exists to remove."
        end

        validate_step_handoff_point!(point) unless point[:mode] == :all

        point
      end
      private :validate_background_declaration!

      def validate_step_handoff_point!(point)
        step_name = point[:step]
        unless steps.key?(step_name)
          raise RubyReactor::Error::ValidationError,
                "`background` names unknown step :#{step_name}. Known steps: " \
                "#{steps.keys.map { |k| ":#{k}" }.join(", ")}. The step must be defined before the " \
                "`background` declaration."
        end

        reject_interrupt_handoff_point!(point)
      end
      private :validate_step_handoff_point!

      def describe_handoff_point(point)
        point[:mode] == :all ? "all: true" : "#{point[:mode]}: :#{point[:step]}"
      end
      private :describe_handoff_point

      # An interrupt re-enters the reactor from a foreground process, so an
      # edge-triggered hand-off keyed to it either never fires (`after:` — the
      # resume path skips the already-resulted step) or enqueues a worker that
      # instantly pauses and swallows the InterruptResult (`before:`). Both are
      # the silent-failure class `background` exists to remove.
      def reject_interrupt_handoff_point!(point)
        config = steps[point[:step]]
        return unless config.respond_to?(:interrupt?) && config.interrupt?

        raise RubyReactor::Error::ValidationError,
              "`background #{point[:mode]}: :#{point[:step]}` names an interrupt step, which cannot be a " \
              "hand-off point. To resume :#{point[:step]} in a worker, declare " \
              "`interrupt :#{point[:step]}, resume: :background` instead; to hand off around it, name an " \
              "ordinary step on the side you need."
      end
      private :reject_interrupt_handoff_point!
      # A step whose work is dispatched to its own independent worker
      # job while this reactor keeps executing every other ready step. Same
      # call shape and same block DSL as `step` — `argument`, `run`,
      # `compensate`, `undo`, `retries`, validators all behave identically;
      # only WHERE the body runs changes.
      #
      # Any step reading `result(:name)` blocks (bounded) until the unit
      # finishes. A failure with no reader does NOT compensate this reactor —
      # compensation is opt-in, via a reader that inspects the result and
      # returns `Failure` itself.
      def async_step(name, impl = nil, &block)
        builder = RubyReactor::Dsl::StepBuilder.new(name, impl, self)
        builder.instance_eval(&block) if block_given?

        steps[name] = builder.build(async_dispatch: :step)
      end

      # Dispatch a whole nested reactor to run INDEPENDENTLY — linked
      # to this one by execution id for traceability, but excluded from its
      # compensation graph. Fire-and-forget unless a later step reads
      # `result(:name)`, which blocks until the child is terminal and hands
      # over the child's real Success/Failure to inspect.
      #
      # Contrast with `compose`, which runs the child inline, synchronously,
      # and fully wired into the parent's rollback path.
      def async_reactor(name, child_reactor_class, &block)
        builder = RubyReactor::Dsl::AsyncReactorBuilder.new(name, child_reactor_class, self)
        builder.instance_eval(&block) if block_given?

        steps[name] = builder.build
      end

      # A reactor's return value must come from a step that ran in the calling
      # process. An `async_step` / `async_reactor` may still be in flight when
      # this reactor finishes — that is the whole point of dispatching it — so
      # returning it would either mean returning nothing or silently turning
      # the fire-and-forget contract into a blocking wait.
      def reject_async_return_step!(step_name)
        config = steps[step_name]
        return unless config.respond_to?(:async_dispatch?) && config.async_dispatch?

        kind = config.async_dispatch == :reactor ? "async_reactor" : "async_step"
        raise RubyReactor::Error::ValidationError,
              "`returns :#{step_name}` is invalid: :#{step_name} is an `#{kind}`, which may still be " \
              "running when this reactor finishes. Return a same-process step instead — if you need the " \
              "dispatched outcome, add a step that reads `result(:#{step_name})` and return that."
      end
      private :reject_async_return_step!
    end
  end
end
