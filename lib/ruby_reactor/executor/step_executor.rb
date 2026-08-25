# frozen_string_literal: true

module RubyReactor
  class Executor
    class StepExecutor
      include AsyncStepDispatch

      def initialize(context:, dependency_graph:, reactor_class:, managers:)
        @context = context
        @dependency_graph = dependency_graph
        @reactor_class = reactor_class
        @retry_manager = managers[:retry_manager]
        @result_handler = managers[:result_handler]
        @compensation_manager = managers[:compensation_manager]
        @middlewares = managers[:middlewares] || context.middlewares || Executor.middlewares_for(reactor_class)
        @on_step_complete = managers[:on_step_complete]
      end

      def execute_all_steps
        until @dependency_graph.all_completed? || @context.finished?
          ready_steps = @dependency_graph.ready_steps

          if ready_steps.empty?
            raise Error::DependencyError.new(
              "No ready steps available but execution not complete",
              context: @context
            )
          end

          # Execute steps sequentially
          ready_steps.each do |step_config|
            result = execute_step(step_config)

            # If step execution was handed off to async, return the async result
            return result if result.is_a?(RubyReactor::AsyncResult)

            # If a step returns RetryQueuedResult, we need to stop and return it
            return result if result.is_a?(RetryQueuedResult)

            # If a step returns Skipped, halt the reactor cleanly (no
            # compensation). Must be checked BEFORE Failure / Success because
            # Skipped is a Success subclass.
            return result if result.is_a?(RubyReactor::Skipped)

            # If a step returns Failure, we need to stop execution and return it
            return result if result.is_a?(RubyReactor::Failure)

            # If a step returns InterruptResult, we need to stop execution and return it
            return result if result.is_a?(RubyReactor::InterruptResult)

            # Only a continue-Success reaches here (Async/Retry/Skipped/Failure/
            # Interrupt all returned above; nil is inline-async test mode). It is
            # the one outcome where the loop proceeds to more steps with no other
            # save in between — every terminal/handoff result persists via its own
            # path. Write a durable checkpoint so a crash re-runs at most this one
            # step. Ordering: side-effect -> record result (inside execute_step) ->
            # checkpoint here.
            @on_step_complete&.call if result.is_a?(RubyReactor::Success)
          end
        end

        # Return the final result
        @result_handler.final_result(@reactor_class)
      end

      def execute_step(step_config)
        if @dependency_graph.completed.include?(step_config.name)
          return RubyReactor.Success(@context.get_result(step_config.name))
        end

        resolved_arguments = resolve_arguments(step_config)

        @middlewares.on(:start_step, step_config.name, resolved_arguments, @context)
        completed = false
        begin
          result = if step_config.interrupt?
                     handle_interrupt_step(step_config)
                   elsif step_config.async_dispatch == :step
                     dispatch_async_step(step_config)
                   elsif handoff_at?(step_config, :before)
                     # `before: :x` hands off INSTEAD of running :x, leaving its
                     # graph node incomplete for the worker to pick up.
                     handle_background_handoff(step_config)
                   else
                     execute_step_with_retry(step_config, resolved_arguments)
                   end
          # `after: :x` hands off once :x's result is recorded — the step really
          # did run here, and only what remains moves to the worker.
          result = handle_background_handoff(step_config) if handoff_after?(step_config, result)
          completed = true
          if result.is_a?(RubyReactor::Failure)
            @middlewares.on(:failed_step, step_config.name, result, @context)
          else
            @middlewares.on(:complete_step, step_config.name, result, @context)
          end
          result
        rescue Exception => e # rubocop:disable Lint/RescueException
          @middlewares.on(:failed_step, step_config.name, e, @context) unless completed
          raise
        end
      end

      private

      # The reactor's single hand-off point, `{ mode: :after|:before, step: }`.
      # Nil for a reactor that never declares `background`.
      def background_handoff
        return @background_handoff if defined?(@background_handoff)

        @background_handoff =
          (@reactor_class.background_handoff if @reactor_class.respond_to?(:background_handoff))
      end

      # Hand-off is keyed to REACHING the named step, not to where the
      # declaration sits in the class body. A step whose `where`/guard says it
      # must not run never triggers it — the hand-off only ever relocates work
      # that is actually going to happen. Inside the worker the whole thing is
      # suppressed (`inline_async_execution`) so it cannot re-trigger.
      def handoff_at?(step_config, mode)
        point = background_handoff
        return false unless point && point[:mode] == mode && point[:step] == step_config.name
        return false if @context.inline_async_execution

        step_config.should_run?(@context)
      end

      # Post-execution trigger for `after:`. Only a plain continue-Success means
      # the named step actually completed here — a Failure, Skipped, interrupt,
      # queued retry or an already-async result each own the flow instead.
      def handoff_after?(step_config, result)
        return false unless result.is_a?(RubyReactor::Success) && !result.is_a?(RubyReactor::Skipped)

        handoff_at?(step_config, :after)
      end

      def reconstruct_failure(data)
        return data if data.is_a?(RubyReactor::Failure)
        return nil unless data.is_a?(Hash)

        # Helper for hash access with string/symbol keys
        get = ->(key) { data[key] || data[key.to_s] }

        RubyReactor::Failure.new(
          get.call(:message),
          step_name: get.call(:step_name),
          inputs: get.call(:inputs),
          redact_inputs: get.call(:redact_inputs) || [],
          backtrace: get.call(:backtrace),
          reactor_name: get.call(:reactor_name),
          step_arguments: get.call(:step_arguments),
          exception_class: get.call(:exception_class),
          file_path: get.call(:file_path),
          line_number: get.call(:line_number),
          code_snippet: get.call(:code_snippet),
          validation_errors: get.call(:validation_errors)
        )
      end

      def execute_step_with_retry(step_config, resolved_arguments = nil)
        resolved_arguments ||= resolve_arguments(step_config)
        result = @retry_manager.execute_with_retry(step_config, @reactor_class) do
          safe_execute_step_sync(step_config, resolved_arguments)
        end

        unless result.is_a?(RetryQueuedResult) || result.is_a?(RubyReactor::AsyncResult)
          @result_handler.handle_step_result(step_config, result, resolved_arguments)
        end

        result
      end

      def safe_execute_step_sync(step_config, resolved_arguments = nil)
        resolved_arguments ||= resolve_arguments(step_config)
        execute_step_sync_without_result_handling(step_config, resolved_arguments)
      rescue Error::InputValidationError
        # Validation failures are not retryable and must surface as a structured
        # InputValidationError (with field_errors), so let them propagate.
        raise
      rescue StandardError => e
        # Identify redacted inputs
        redact_inputs = @reactor_class.inputs.select { |_, config| config[:redact] }.keys

        RubyReactor::Failure(
          e,
          step_name: step_config.name,
          inputs: @context.inputs,
          redact_inputs: redact_inputs,
          reactor_name: @reactor_class.name,
          step_arguments: resolved_arguments
        )
      end

      def execute_step_sync(step_config, resolved_arguments = nil)
        @context.with_step(step_config.name) do
          # Check conditions and guards
          unless step_config.should_run?(@context)
            @dependency_graph.complete_step(step_config.name)
            return RubyReactor.Success(nil)
          end

          # Resolve arguments
          resolved_arguments ||= resolve_arguments(step_config)

          # Validate arguments if validator is defined
          validate_step_arguments(step_config, resolved_arguments)

          # Execute the step
          result = run_step_implementation(step_config, resolved_arguments)

          # Handle the result
          @result_handler.handle_step_result(step_config, result, resolved_arguments)
        end
      end

      # Execute step without handling the result (used during retries)
      def execute_step_sync_without_result_handling(step_config, resolved_arguments = nil)
        @context.with_step(step_config.name) do
          # Check conditions and guards
          unless step_config.should_run?(@context)
            @dependency_graph.complete_step(step_config.name)
            return RubyReactor.Success(nil)
          end

          # Resolve arguments
          resolved_arguments ||= resolve_arguments(step_config)

          yield resolved_arguments if block_given?

          # Validate arguments if validator is defined
          validate_step_arguments(step_config, resolved_arguments)

          # Execute the step
          run_step_implementation(step_config, resolved_arguments)
        end
      end

      # Hand every step not yet executed to a worker job, and return the
      # `AsyncResult` that halts `execute_all_steps` in the calling process.
      # Shared verbatim by both `background` forms — they differ only in WHERE
      # the trigger sits, never in what the hand-off does.
      def handle_background_handoff(step_config)
        log_async_event("background.handoff", step_config.name)
        @context.current_step = step_config.name
        @context.undo_stack = @compensation_manager.undo_stack

        # Use root context if available to ensure we serialize the full tree
        context_to_serialize = @context.root_context || @context
        reactor_class_name = RubyReactor.reactor_storage_name(context_to_serialize.reactor_class)

        # Inject OTel context before serialization
        @middlewares.on(:before_async_enqueue, context_to_serialize)

        # Storage is load-bearing: the job payload is identity-only, so the root
        # context MUST be persisted BEFORE the job is enqueued (F2). The reactor
        # class name used for the storage key must match the one handed to the
        # worker, so compute it once and reuse it for both.
        checkpoint_root!(context_to_serialize, reactor_class_name)

        configuration.async_router.perform_async(
          context_to_serialize.context_id,
          reactor_class_name,
          intermediate_results: @context.intermediate_results
        )
      end

      # Persist the root context under its storage key. Mirrors Executor#checkpoint!
      # but lives here because handle_async_step runs inside the StepExecutor and
      # must serialize AFTER the before_async_enqueue middleware has injected its
      # OTel context.
      def checkpoint_root!(root, reactor_class_name)
        storage = RubyReactor::Configuration.instance.storage_adapter
        storage.store_context(root.context_id, ContextSerializer.serialize(root), reactor_class_name)
      end

      def handle_interrupt_step(step_config)
        # Check if we have a result for this step (resuming)
        if @context.intermediate_results.key?(step_config.name)
          # We are resuming
          result = @context.get_result(step_config.name)
          return RubyReactor.Success(result)
        end

        # We are pausing
        correlation_id = nil
        correlation_id = step_config.correlation_id_block.call(@context) if step_config.correlation_id_block

        # Store current step as the one we are paused at
        @context.current_step = step_config.name

        RubyReactor::InterruptResult.new(
          execution_id: @context.context_id,
          correlation_id: correlation_id,
          intermediate_results: @context.intermediate_results
        )
      end

      def configuration
        RubyReactor::Configuration.instance
      end

      def validate_step_arguments(step_config, resolved_arguments)
        return unless step_config.args_validator

        validation_result = step_config.args_validator.call(resolved_arguments)
        return if validation_result.success?

        # Stamp step attribution so the resulting Failure can say WHERE the
        # validation failed, not just what was invalid.
        error = validation_result.error
        error.step_name = step_config.name
        error.step_arguments = resolved_arguments
        raise error
      end

      def resolve_arguments(step_config)
        resolved = {}

        step_config.arguments.each do |arg_name, arg_config|
          source = arg_config[:source]
          transform = arg_config[:transform]

          value = source.resolve(@context)
          value = transform.call(value) if transform

          resolved[arg_name] = value
        end

        resolved
      end

      def run_step_implementation(step_config, arguments)
        @context.execution_trace << { type: :run, step: step_config.name, timestamp: Time.now, arguments: arguments }
        if step_config.has_run_block?
          # Execute inline block
          # If no arguments are defined for the step, pass the reactor inputs as arguments
          args_to_pass = arguments.empty? ? @context.inputs : arguments
          step_config.run_block.call(args_to_pass, @context)
        elsif step_config.has_impl?
          # Execute step class
          step_config.impl.run(arguments, @context)
        else
          raise Error::ValidationError.new(
            "Step '#{step_config.name}' has no implementation",
            step: step_config.name,
            context: @context
          )
        end
      end

      def find_context_by_id(root_context, target_id)
        return root_context if root_context.context_id == target_id

        # Search in composed contexts
        root_context.composed_contexts.each_value do |composed_data|
          # composed_data is a hash with :context key
          next unless composed_data.is_a?(Hash) && composed_data[:context].is_a?(RubyReactor::Context)

          found = find_context_by_id(composed_data[:context], target_id)
          return found if found
        end

        nil
      end
    end
  end
end
