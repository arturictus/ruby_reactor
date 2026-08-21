# frozen_string_literal: true

module RubyReactor
  # The body of one dispatched `async_step`, shared by every queueing backend
  # (`Adapters::Sidekiq::StepWorker`, `Adapters::ActiveJob::StepWorker`) exactly
  # as `Map::ElementExecutor` is shared by the map element workers.
  #
  # It is deliberately NOT a reactor run: it loads the parent context, resolves
  # just this one step's arguments against it, runs the step body, writes the
  # durable Step Result Record, and publishes the completion signal. Ordering is
  # load-bearing — the record is written BEFORE the signal, so a reader that
  # misses the (at-most-once) signal still finds the answer on its next
  # fallback re-check.
  class StepWorker
    class << self
      def perform(arguments)
        arguments = arguments.transform_keys(&:to_sym)
        new(**slice_arguments(arguments)).perform
      end

      private

      def slice_arguments(arguments)
        {
          root_context_id: arguments[:root_context_id],
          reactor_class_name: arguments[:reactor_class_name],
          step_context_id: arguments[:step_context_id],
          step_name: arguments[:step_name].to_sym
        }
      end
    end

    def initialize(root_context_id:, reactor_class_name:, step_context_id:, step_name:)
      @root_context_id = root_context_id
      @reactor_class_name = reactor_class_name
      @step_context_id = step_context_id || root_context_id
      @step_name = step_name
    end

    def perform
      context = load_step_context
      return record_missing_parent unless context

      step_config = context.reactor_class&.steps&.[](@step_name)
      return record_missing_step unless step_config

      complete(run_step(context, step_config), context)
    rescue StandardError => e
      # The unit's failure belongs in its record, where a reader can see it.
      # Raising instead would hand the job to the backend's retry machinery to
      # fail identically N more times while every reader waits out its timeout.
      log(:error, "failed", error: "#{e.class}: #{e.message}")
      complete(RubyReactor.Failure(e, step_name: @step_name, reactor_name: @reactor_class_name), nil)
    end

    private

    def run_step(context, step_config)
      arguments = resolve_arguments(step_config, context)
      log(:info, "running")

      result =
        if step_config.has_run_block?
          args = arguments.empty? ? context.inputs : arguments
          step_config.run_block.call(args, context)
        elsif step_config.has_impl?
          step_config.impl.run(arguments, context)
        else
          RubyReactor.Failure("Step '#{@step_name}' has no implementation")
        end

      normalize(result)
    end

    def normalize(result)
      return result if result.is_a?(RubyReactor::Success) || result.is_a?(RubyReactor::Failure)

      RubyReactor.Success(result)
    end

    def resolve_arguments(step_config, context)
      step_config.arguments.to_h do |arg_name, arg_config|
        value = arg_config[:source].resolve(context)
        value = arg_config[:transform].call(value) if arg_config[:transform]
        [arg_name, value]
      end
    end

    # Write first, publish second. The record is the answer; the signal only
    # saves the reader a fallback interval.
    def complete(result, context)
      storage.store_step_result(
        @step_context_id, @step_name,
        {
          "status" => "completed",
          "success" => result.success?,
          "result" => ContextSerializer.serialize_value(result.success? ? result.value : result.to_h),
          "completed_at" => Time.now.iso8601
        },
        @reactor_class_name
      )
      log(result.success? ? :info : :warn, result.success? ? "completed" : "completed_with_failure")
      storage.publish(RubyReactor.async_step_channel(@step_context_id, @step_name), "done")
      result
    ensure
      # A step body may have mutated the sub-context; nothing else will persist
      # it, and the dashboard reads the parent's blob.
      save_root(context) if context
    end

    def record_missing_parent
      # FR-018: the parent was swept or outlived its retention window, so this
      # unit's arguments can never be resolved. A record saying so beats a
      # reader waiting out the full timeout for an answer that will never come.
      log(:error, "parent_context_missing")
      complete(
        RubyReactor.Failure(
          "Parent context #{@step_context_id} for async_step :#{@step_name} is no longer in storage " \
          "(swept, or dispatched longer ago than `context_ttl`). The step's arguments cannot be resolved."
        ),
        nil
      )
    end

    def record_missing_step
      log(:error, "step_not_found")
      complete(
        RubyReactor.Failure("async_step :#{@step_name} is not defined on #{@reactor_class_name}"),
        nil
      )
    end

    def load_step_context
      data = storage.retrieve_context(@root_context_id, @reactor_class_name)
      return nil unless data

      root = ContextSerializer.deserialize_hash(data)
      @root_context = root
      found = find_context(root, @step_context_id)
      # The step runs in its own job; nothing it reaches should hand off again.
      found&.inline_async_execution = true
      found
    rescue RubyReactor::Error::DeserializationError, RubyReactor::Error::SchemaVersionError => e
      log(:error, "parent_context_unreadable", error: "#{e.class}: #{e.message}")
      nil
    end

    def find_context(context, target_id)
      return context if context.context_id == target_id

      context.composed_contexts.each_value do |entry|
        next unless entry.is_a?(Hash) && entry[:context].is_a?(RubyReactor::Context)

        found = find_context(entry[:context], target_id)
        return found if found
      end
      nil
    end

    def save_root(_context)
      return unless @root_context

      storage.store_context(@root_context.context_id, ContextSerializer.serialize(@root_context),
                            @reactor_class_name)
    rescue StandardError => e
      RubyReactor.configuration.logger.warn(
        "RubyReactor: async_step :#{@step_name} could not persist its parent context: #{e.message}"
      )
    end

    def storage
      RubyReactor.configuration.storage_adapter
    end

    # FR-012: machine-parseable, and carrying enough identity to correlate a
    # worker-side outcome with the parent execution — which matters more here
    # than elsewhere, because a fire-and-forget failure may have no other surface.
    def log(level, event, **extra)
      fields = {
        event: "ruby_reactor.async_step.#{event}",
        reactor: @reactor_class_name,
        step: @step_name,
        execution_id: @step_context_id
      }.merge(extra)

      RubyReactor.configuration.logger.public_send(
        level, fields.map { |k, v| "#{k}=#{v.inspect}" }.join(" ")
      )
    end
  end
end
