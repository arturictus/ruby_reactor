# frozen_string_literal: true

module RubyReactor
  class Executor
    class StepExecutor
      def initialize(context:, dependency_graph:, reactor_class:, managers:)
        @context = context
        @dependency_graph = dependency_graph
        @reactor_class = reactor_class
        @retry_manager = managers[:retry_manager]
        @result_handler = managers[:result_handler]
        @compensation_manager = managers[:compensation_manager]
      end

      def execute_all_steps
        until @dependency_graph.all_completed?
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

            # If a step returns Failure, we need to stop execution and return it
            return result if result.is_a?(RubyReactor::Failure)

            # If a step returns InterruptResult, we need to stop execution and return it
            return result if result.is_a?(RubyReactor::InterruptResult)

            # If result is nil, it means async was executed inline (test mode), continue
            next if result.nil?
          end
        end

        # Return the final result
        @result_handler.final_result(@reactor_class)
      end

      def execute_step(step_config)
        # If we're already in inline async execution mode (inside Worker),
        # treat async steps as sync to avoid infinite recursion

        if step_config.interrupt?
          handle_interrupt_step(step_config)
        elsif step_config.async? && !@context.inline_async_execution
          handle_async_step(step_config)
        else
          execute_step_with_retry(step_config)
        end
      end

      def merge_executor_state(other_executor)
        # Merge the state from the async-executed executor back into ours
        # We need to update our context IN PLACE, not replace the reference,
        # because the Executor also holds a reference to the same context object

        # Update intermediate results
        other_executor.context.intermediate_results.each do |step_name, value|
          @context.set_result(step_name, value)
        end

        # Append execution trace from the async execution
        # The Worker's execution will have ALL steps including ones we already executed,
        # but we only want to add the NEW entries (from current_step onwards)
        current_trace_length = @context.execution_trace.length
        new_trace_entries = other_executor.context.execution_trace[current_trace_length..] || []

        @context.execution_trace.concat(new_trace_entries)

        # Update retry context
        @context.retry_context = other_executor.context.retry_context

        # Clear current_step since we've completed it
        @context.current_step = nil

        # Update our dependency graph to reflect completed steps
        other_executor.context.intermediate_results.each_key do |step_name|
          @dependency_graph.complete_step(step_name)
        end

        # Also mark the current_step as completed if it exists (for failed steps that don't have results)
        @dependency_graph.complete_step(other_executor.context.current_step) if other_executor.context.current_step

        # Merge any undo stack items
        other_executor.undo_stack.each do |item|
          # Avoid duplicates by checking if this step is already in the undo stack
          # Use string comparison for step names to avoid symbol/string mismatch issues
          unless @compensation_manager.undo_stack.any? { |existing| existing[:step].name.to_s == item[:step].name.to_s }
            @compensation_manager.add_to_undo_stack(item)
          end
        end

        # Merge undo trace from the other executor
        other_executor.undo_trace.each do |trace_entry|
          @compensation_manager.undo_trace << trace_entry
        end
      end

      def execute_step_with_retry(step_config)
        result = @retry_manager.execute_with_retry(step_config, @reactor_class) do
          safe_execute_step_sync(step_config)
        end

        unless result.is_a?(RetryQueuedResult) || result.is_a?(RubyReactor::AsyncResult)
          resolved_arguments = resolve_arguments(step_config)
          @result_handler.handle_step_result(step_config, result, resolved_arguments)
        end

        result
      end

      def safe_execute_step_sync(step_config)
        resolved_arguments = {}
        execute_step_sync_without_result_handling(step_config) do |args|
          resolved_arguments = args
        end
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

      def execute_step_sync(step_config)
        @context.with_step(step_config.name) do
          # Check conditions and guards
          unless step_config.should_run?(@context)
            @dependency_graph.complete_step(step_config.name)
            return RubyReactor.Success(nil)
          end

          # Resolve arguments
          resolved_arguments = resolve_arguments(step_config)

          # Validate arguments if validator is defined
          validate_step_arguments(step_config, resolved_arguments)

          # Execute the step
          result = run_step_implementation(step_config, resolved_arguments)

          # Handle the result
          @result_handler.handle_step_result(step_config, result, resolved_arguments)
        end
      end

      # Execute step without handling the result (used during retries)
      def execute_step_sync_without_result_handling(step_config)
        @context.with_step(step_config.name) do
          # Check conditions and guards
          unless step_config.should_run?(@context)
            @dependency_graph.complete_step(step_config.name)
            return RubyReactor.Success(nil)
          end

          # Resolve arguments
          resolved_arguments = resolve_arguments(step_config)

          yield resolved_arguments if block_given?

          # Validate arguments if validator is defined
          validate_step_arguments(step_config, resolved_arguments)

          # Execute the step
          run_step_implementation(step_config, resolved_arguments)
        end
      end

      private

      def handle_async_step(step_config)
        # Step-level async: hand off execution to worker

        @context.current_step = step_config.name
        @context.undo_stack = @compensation_manager.undo_stack

        # Use root context if available to ensure we serialize the full tree
        context_to_serialize = @context.root_context || @context
        reactor_class_name = context_to_serialize.reactor_class.name

        serialized_context = ContextSerializer.serialize(context_to_serialize)

        result = configuration.async_router.perform_async(
          serialized_context,
          reactor_class_name,
          intermediate_results: @context.intermediate_results
        )

        # Handle different result types from async router
        case result
        when RubyReactor::AsyncResult
          # Production behavior: return async result to caller

          result
        when Executor
          handle_inline_executor_result(result)
        else
          # Unexpected result type, treat as error
          raise Error::ValidationError.new(
            "Unexpected result type from async router: #{result.class}",
            context: @context
          )
        end
      end

      def handle_inline_executor_result(result)
        # Worker executed inline and returned an executor.
        # This happens when running in test mode or when perform_async returns an executor.
        # We need to merge the state back into our current executor.
        #
        # If we are a child reactor, the worker executed the root reactor, so the result
        # will be a Root executor. We handle this mismatch below by finding our
        # corresponding child context within the root result.
        if @context.root_context && (result.context.reactor_class != @reactor_class)
          # We are a child, and result is root.
          # We need to find ourselves in the root result using context_id.
          matching_context = find_context_by_id(result.context, @context.context_id)

          if matching_context
            # Replace the result's context with the matching child context
            # so merge_executor_state works correctly
            result.instance_variable_set(:@context, matching_context)
          else
            # Fallback: if we can't find it (shouldn't happen), we might be in trouble.
            # But let's try to proceed, maybe it's not nested?
            # For now, raise an error to be explicit
            raise Error::ValidationError.new(
              "Could not find child context with ID #{@context.context_id} in root result",
              context: @context
            )
          end
        end

        merge_executor_state(result)

        result.result
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

        raise Error::StepFailureError.new(
          "Step '#{step_config.name}' argument validation failed: #{validation_result.error.message}",
          step: step_config.name,
          context: @context
        )
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
