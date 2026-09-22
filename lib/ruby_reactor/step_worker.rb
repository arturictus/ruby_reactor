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
  # rubocop:disable Metrics/ClassLength
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
          step_name: arguments[:step_name].to_sym,
          contention_attempts: arguments[:contention_attempts] || 0
        }
      end
    end

    def initialize(root_context_id:, reactor_class_name:, step_context_id:, step_name:, contention_attempts: 0)
      @root_context_id = root_context_id
      @reactor_class_name = reactor_class_name
      @step_context_id = step_context_id || root_context_id
      @step_name = step_name
      @contention_attempts = contention_attempts.to_i
    end

    # The lock is what makes a lost unit recoverable: the record alone cannot say
    # whether a `dispatched` unit is mid-flight or gone, so StepSweeper reads this
    # lock as the liveness signal. It also drops a duplicate delivery rather than
    # running the body a second time.
    def perform
      lock = acquire_liveness_lock
      return if lock == :contended

      perform_unit
    ensure
      lock.release if lock.respond_to?(:release)
    end

    private

    def perform_unit
      context = load_step_context
      return record_missing_parent unless context

      # A fresh worker process has never run the reactor, so the inferred
      # wiring for name-resolved inputs does not exist here yet.
      context.reactor_class&.validate_definition!
      step_config = context.reactor_class&.steps&.[](@step_name)
      return record_missing_step unless step_config

      complete(run_step(context, step_config), context)
    rescue Executor::StepCoordination::Contended => e
      handle_contention(e, context)
    rescue Executor::StepCoordination::KeyError => e
      log(:error, "failed", error: "#{e.class}: #{e.message}")
      complete(RubyReactor.Failure(e, step_name: @step_name, reactor_name: @reactor_class_name, retryable: false),
               context)
    rescue StandardError => e
      # The unit's failure belongs in its record, where a reader can see it.
      # Raising instead would hand the job to the backend's retry machinery to
      # fail identically N more times while every reader waits out its timeout.
      log(:error, "failed", error: "#{e.class}: #{e.message}")
      complete(RubyReactor.Failure(e, step_name: @step_name, reactor_name: @reactor_class_name), nil)
    end

    # Finding 6: `async_step` has no delayed re-enqueue of its own, so a
    # contended step parks the same way a step-level contention park does
    # elsewhere — reschedule via `perform_step_in`, bounded by
    # `lock_snooze_max_attempts` (the `OrderedLock::WaitError` exemption
    # mirrors `Worker#handle_snooze`). WITHOUT calling `complete`: the Step
    # Result Record stays "dispatched" so a reader keeps waiting instead of
    # seeing a phantom terminal state.
    def handle_contention(contended, context = nil)
      config = RubyReactor.configuration
      attempt = @contention_attempts + 1
      uncapped = contended.original.is_a?(RubyReactor::OrderedLock::WaitError)

      if !uncapped && config.lock_snooze_max_attempts != :infinity && attempt > config.lock_snooze_max_attempts
        log(:warn, "contention_exhausted", key: contended.key, attempt: attempt)
        # Terminal: an earlier attempt parked, which deliberately KEEPS this
        # step's state for a redelivery — the park marker (or the parent stays
        # marked waiting on a key), a detached lock, a checked-out semaphore
        # token, a remembered rate-limit charge and an un-advanced ordered-lock
        # position. No redelivery is coming, so hand it all back; `context` is
        # passed on so `complete`'s `save_root` persists the cleared state.
        Executor::StepCoordination.discard_parked_state!(context) if context
        complete(
          RubyReactor::Failure(
            "async_step :#{@step_name} gave up on #{contended.primitive} '#{contended.key}' after " \
            "#{attempt} contention attempts",
            step_name: @step_name, reactor_name: @reactor_class_name, retryable: false,
            exception_class: contended.original.class.name
          ), context
        )
        return
      end

      delay = RubyReactor::Worker.snooze_delay(config, contended)
      log(:info, "parked", key: contended.key, primitive: contended.primitive, attempt: attempt, delay: delay)
      record_contention(context, contended, attempt)
      RubyReactor.configuration.async_router.perform_step_in(
        delay, root_context_id: @root_context_id, reactor_class_name: @reactor_class_name,
               step_context_id: @step_context_id, step_name: @step_name, contention_attempts: attempt
      )
    end

    # The same park evidence `StepExecutor#handle_contention` writes, so a
    # reader sees this unit waiting on its key instead of merely pending.
    # Persisted here because nothing else saves the context on this path —
    # `complete` (which would) is deliberately not called while parked.
    def record_contention(context, contended, attempt)
      return unless context

      context.append_execution_trace(
        { type: :contention_park, step: @step_name, primitive: contended.primitive, key: contended.key,
          attempt: attempt, timestamp: Time.now }
      )
      context.private_data[:step_contention] = {
        step: @step_name, primitive: contended.primitive, key: contended.key, attempts: attempt,
        next_attempt_at: nil
      }
      save_root(context)
    end

    def acquire_liveness_lock
      # Inline testing re-enters this frame synchronously, so the lock would
      # self-contend; it only guards cross-process delivery, impossible inline.
      return :inline if inline_testing_mode?

      lock = RubyReactor::Lock.new(
        RubyReactor.async_step_lock_key(@step_context_id, @step_name),
        owner: SecureRandom.uuid, ttl: RubyReactor.configuration.context_lock_ttl,
        wait: 0, auto_extend: true
      )
      lock.acquire
      lock
    rescue RubyReactor::Lock::AcquisitionError
      log(:info, "duplicate_dropped")
      :contended
    end

    def inline_testing_mode?
      defined?(Sidekiq::Testing) && Sidekiq::Testing.respond_to?(:inline?) && Sidekiq::Testing.inline?
    end

    def run_step(context, step_config)
      arguments = resolve_arguments(step_config, context)
      # Reactor-side `argument`/`validate_args` rules gate the step BEFORE its
      # coordination is acquired, exactly as `StepExecutor#execute_step_sync`
      # orders them — an async_step must not take a lock (or spend a rate-limit
      # slot) for arguments it is about to reject.
      invalid = validate_arguments(step_config, arguments)
      return invalid if invalid

      log(:info, "running")
      # Mirrors `StepExecutor#run_step_implementation`: without a `:run` entry
      # the dashboard has no arguments to resolve this step's key from.
      contract = step_config.input_contract
      context.append_execution_trace(
        { type: :run, step: @step_name, timestamp: Time.now,
          arguments: contract ? contract.redact(arguments) : arguments }
      )

      attempt = 0
      result = nil

      loop do
        attempt += 1
        # Mirror the count onto the context: `StepCoordination` reads
        # `retry_context` to decide whether an ordered-lock position should be
        # held for a pending retry, and this worker is the one path that never
        # goes through `RetryManager#prepare_retry_attempt`.
        context.retry_context.increment_attempt_for_step(@step_name)
        result = execute_step_body(step_config, arguments, context)
        break unless retry?(step_config, result, attempt)

        delay = backoff_delay(step_config, attempt)
        log(:warn, "retrying", attempt: attempt, delay: delay)
        sleep(delay)
      end

      result
    end

    # Same check and same structured, non-retryable shape `StepExecutor`
    # produces — the same arguments fail the same rules on every attempt.
    def validate_arguments(step_config, arguments)
      return nil unless step_config.args_validator

      validation_result = step_config.args_validator.call(arguments)
      return nil if validation_result.success?

      error = validation_result.error
      error.step_name = @step_name
      error.step_arguments = arguments
      log(:warn, "invalid_arguments", error: "#{error.class}: #{error.message}")
      RubyReactor.Failure(error, validation_errors: error.field_errors, step_name: @step_name,
                                 step_arguments: arguments, reactor_name: @reactor_class_name,
                                 retryable: false)
    end

    # Class steps are already coordinated inside `Step.run` (T013); only the
    # inline (`has_run_block?`) branch needs its own wrap here, mirroring
    # `StepExecutor#run_inline_block`. `Contended`/`KeyError` propagate
    # unrescued — `perform_unit` is where they are handled (park, or a
    # non-retryable Failure), not here.
    def execute_step_body(step_config, arguments, context)
      result =
        if step_config.has_run_block?
          args = arguments.empty? ? context.inputs : arguments
          args = step_config.inline_contract.enforce!(args) if step_config.inline_contract
          run_inline_block(step_config, args, context)
        elsif step_config.has_impl?
          step_config.impl.run(arguments, context)
        else
          RubyReactor.Failure("Step '#{@step_name}' has no implementation")
        end

      normalize(result)
    rescue Error::InputValidationError => e
      # Same shape the executor builds, and never retried: the same arguments
      # fail the same contract on every attempt.
      RubyReactor.Failure(e, validation_errors: e.field_errors, step_name: @step_name,
                             step_arguments: e.step_arguments || {}, reactor_name: @reactor_class_name,
                             retryable: false)
    rescue Executor::StepCoordination::Contended, Executor::StepCoordination::KeyError
      raise
    rescue StandardError => e
      RubyReactor.Failure(e, step_name: @step_name, reactor_name: @reactor_class_name)
    end

    def run_inline_block(step_config, args, context)
      block = -> { step_config.run_block.call(args, context) }
      return block.call unless step_config.inline_coordination?

      Executor::StepCoordination.new(
        step_config: step_config, arguments: args, context: context, reactor_class: context.reactor_class,
        middlewares: context.middlewares || RubyReactor::MiddlewareRunner.new([])
      ).around_run(&block)
    end

    # Mirrors `Executor::RetryManager#can_retry_step?` for the one path that
    # never reaches it: an `async_step`'s body runs entirely inside this
    # worker, so retries here must be attempted synchronously in-process
    # rather than requeued as a new job.
    def retry?(step_config, result, attempt)
      return false unless result.is_a?(RubyReactor::Failure) && result.retryable?

      step_config.retryable? && attempt < step_config.retry_config[:max_attempts]
    end

    def backoff_delay(step_config, attempt)
      RetryContext.calculate_backoff_delay(
        attempt, step_config.retry_config[:backoff], step_config.retry_config[:base_delay]
      )
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
      record = {
        "status" => "completed",
        "success" => result.success?,
        "result" => ContextSerializer.serialize_value(result.success? ? result.value : result.to_h),
        "completed_at" => Time.now.iso8601
      }
      # A `halt!` reports success? == true but carries no value, so without
      # this the reader cannot tell it from an ordinary success returning nil.
      # `skip!` needs nothing extra: Skipped keeps its value, and the reader is
      # meant to see that value exactly as a same-process step would.
      if result.is_a?(RubyReactor::Halt)
        record["signal"] = "halt"
        record["reason"] = result.reason
      end
      storage.store_step_result(@step_context_id, @step_name, record, @reactor_class_name)
      log(result.success? ? :info : :warn, result.success? ? "completed" : "completed_with_failure")
      storage.publish(RubyReactor.async_step_channel(@step_context_id, @step_name), "done")
      result
    ensure
      # A step body may have mutated the sub-context; nothing else will persist
      # it, and the dashboard reads the parent's blob.
      save_root(context) if context
    end

    def record_missing_parent
      # The parent was swept or outlived its retention window, so this
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
      # Per-job owner, NEVER the root context id (US4-5, research D5):
      # ownership never crosses a process hand-off, so this job's coordination
      # never re-enters the dispatching execution's holds and never blocks a
      # SECOND async_step dispatch on the same key from proceeding once this
      # one releases. Derived, not random: `StepCoordination` can detach a
      # lock across a contention park, and `perform_step_in` redelivers this
      # same unit — a fresh uuid per redelivery would make `lock.reattach`
      # fail against its own detached hold until the TTL expired.
      found&.coordination_owner = "async_step:#{@step_context_id}:#{@step_name}"
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

    # Machine-parseable, and carrying enough identity to correlate a
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
  # rubocop:enable Metrics/ClassLength
end
