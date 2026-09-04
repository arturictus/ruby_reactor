# frozen_string_literal: true

module RubyReactor
  module Template
    class Result < Base
      attr_reader :step_name, :path

      def initialize(step_name, path = nil)
        super()
        @step_name = step_name
        @path = path
      end

      # For an ordinary step this is exactly what it always was: read the
      # recorded result. The async branch only engages when there is no recorded
      # result AND the context carries an async reference for this name, so a
      # synchronous reference costs one extra hash lookup and nothing else.
      def resolve(context)
        value = context.get_result(@step_name)
        value = resolve_async_reference(context) if value.nil?
        return nil if value.nil?

        @path ? extract_path(value, @path) : value
      end

      def inspect
        if @path
          "result(:#{@step_name}, #{@path.inspect})"
        else
          "result(:#{@step_name})"
        end
      end

      # Seconds a WORKER-side reader blocks in-thread before parking. Long
      # enough that a unit finishing "immediately" (the common case) resolves
      # without a park round-trip; short enough that a genuinely slow unit
      # frees the worker thread quickly. Not configurable — the tunable bounds
      # are `async_wait_timeout` (blocking) and `async_park_timeout` (parked).
      PARK_GRACE = 5.0

      private

      # Block (bounded) until the dispatched unit is terminal,
      # then inject its outcome.
      def resolve_async_reference(context)
        ref = async_reference(context)
        return nil unless ref

        case fetch(ref, :type).to_s
        when "async_step_ref" then await_async_step(context, ref)
        when "async_reactor_ref" then await_async_reactor(context, ref)
        end
      end

      def async_reference(context)
        ref = context.composed_contexts[@step_name] ||
              context.composed_contexts[@step_name.to_s] ||
              context.composed_contexts[@step_name.to_sym]
        ref if ref.is_a?(Hash)
      end

      # Read semantics: on Success the reader gets the same raw
      # deserialized value a same-process step would have produced. On Failure it
      # gets the `Failure` OBJECT — a same-process failure would have halted the
      # reactor before any reader ran, so there is no sync behavior to mirror,
      # and handing over the Failure is precisely what lets the reader see it and
      # decide whether to compensate.
      def await_async_step(context, ref)
        reactor_class_name = RubyReactor.reactor_storage_name(context.reactor_class)
        record = awaited(
          context, ref,
          channel: RubyReactor.async_step_channel(context.context_id, @step_name)
        ) do
          stored = storage.retrieve_step_result(context.context_id, @step_name, reactor_class_name)
          stored if stored && fetch(stored, :status).to_s == "completed"
        end

        value = ContextSerializer.deserialize_value(fetch(record, :result))
        return value if fetch(record, :success)

        RubyReactor::Failure.new(value)
      end

      # The child is an ordinary addressable reactor, so "terminal" is just its
      # own context row reaching a terminal status — no extra storage primitive.
      # A child PAUSED at an interrupt is deliberately not terminal: the reader
      # keeps waiting (and may time out) unless the child is resumed.
      def await_async_reactor(context, ref)
        execution_id = fetch(ref, :execution_id)
        reactor_class_name = fetch(ref, :reactor_class_name)

        data = awaited(context, ref, channel: RubyReactor.async_reactor_channel(execution_id)) do
          stored = storage.retrieve_context(execution_id, reactor_class_name)
          stored if stored && terminal_status?(stored)
        end

        child_result(data)
      end

      # A synchronous caller (a request thread, a rake task) blocks in the
      # notified wait, bounded tight by `async_wait_timeout` — it has a thread
      # to spare and a host timeout to stay under. Inside a WORKER the same
      # read must not pin the thread: after PARK_GRACE it raises
      # `AsyncResultPending`, the executor keeps its locks held and the job
      # re-enqueues itself, re-entering this method on redelivery. Total parked
      # time is bounded by `async_park_timeout` measured from `dispatched_at`.
      def awaited(context, ref, channel:, &check)
        return RubyReactor::AsyncWaiter.new(channel: channel, &check).wait unless worker_process?(context)

        begin
          RubyReactor::AsyncWaiter.new(channel: channel, timeout: PARK_GRACE, &check).wait
        rescue Error::AsyncWaitTimeoutError
          raise park_expired_error(channel) if park_deadline_passed?(ref)

          raise Error::AsyncResultPending.new(
            "async result for '#{@step_name}' still pending on '#{channel}'; parking the caller",
            channel: channel
          )
        end
      end

      def worker_process?(context)
        (context.root_context || context).inline_async_execution
      end

      def park_deadline_passed?(ref)
        limit = RubyReactor.configuration.async_park_timeout
        return false if limit == :infinity

        Time.now - park_clock_start(ref) >= limit
      end

      # `dispatched_at` round-trips through serialization, so it may come back
      # as a string; an unparseable/missing stamp starts the clock at the first
      # park rather than waiving the bound.
      def park_clock_start(ref)
        raw = fetch(ref, :dispatched_at)
        return raw if raw.is_a?(Time)

        begin
          Time.parse(raw.to_s)
        rescue ArgumentError, TypeError
          ref[:dispatched_at] = Time.now
        end
      end

      def park_expired_error(channel)
        Error::AsyncWaitTimeoutError.new(
          "Parked wait for '#{@step_name}' on '#{channel}' exceeded " \
          "`RubyReactor.configuration.async_park_timeout` " \
          "(#{RubyReactor.configuration.async_park_timeout}s since dispatch) without the unit " \
          "reaching a terminal state — check that a worker is consuming the queue, or raise the " \
          "timeout if this unit is legitimately slower."
        )
      end

      def terminal_status?(data)
        %w[completed failed cancelled skipped].include?(fetch(data, :status).to_s)
      end

      # The child's real Success/Failure, never the enqueue-time DispatchResult —
      # the reader is supposed to inspect `.success?` / `.value` / `.error`.
      def child_result(data)
        context = RubyReactor::Context.deserialize_from_retry(data)
        return context.failure_reason if context.failure_reason.is_a?(RubyReactor::Failure)
        return RubyReactor::Failure.new(context.failure_reason || "child reactor failed") if context.failed?

        return_step = context.reactor_class.respond_to?(:return_step) ? context.reactor_class.return_step : nil
        RubyReactor::Success.new(return_step ? context.get_result(return_step) : nil)
      end

      def storage
        RubyReactor.configuration.storage_adapter
      end

      # Records round-trip through JSON, so a key may come back as a string.
      def fetch(hash, key)
        hash[key] || hash[key.to_s]
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
    end
  end
end
