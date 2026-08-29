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

      private

      # Block (bounded) until the dispatched unit is terminal,
      # then inject its outcome.
      def resolve_async_reference(context)
        ref = async_reference(context)
        return nil unless ref

        case fetch(ref, :type).to_s
        when "async_step_ref" then await_async_step(context)
        when "async_reactor_ref" then await_async_reactor(ref)
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
      def await_async_step(context)
        reactor_class_name = RubyReactor.reactor_storage_name(context.reactor_class)
        record = RubyReactor::AsyncWaiter.new(
          channel: RubyReactor.async_step_channel(context.context_id, @step_name)
        ) do
          stored = storage.retrieve_step_result(context.context_id, @step_name, reactor_class_name)
          stored if stored && fetch(stored, :status).to_s == "completed"
        end.wait

        value = ContextSerializer.deserialize_value(fetch(record, :result))
        return value if fetch(record, :success)

        RubyReactor::Failure.new(value)
      end

      # The child is an ordinary addressable reactor, so "terminal" is just its
      # own context row reaching a terminal status — no extra storage primitive.
      # A child PAUSED at an interrupt is deliberately not terminal: the reader
      # keeps waiting (and may time out) unless the child is resumed.
      def await_async_reactor(ref)
        execution_id = fetch(ref, :execution_id)
        reactor_class_name = fetch(ref, :reactor_class_name)

        data = RubyReactor::AsyncWaiter.new(
          channel: RubyReactor.async_reactor_channel(execution_id)
        ) do
          stored = storage.retrieve_context(execution_id, reactor_class_name)
          stored if stored && terminal_status?(stored)
        end.wait

        child_result(data)
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
