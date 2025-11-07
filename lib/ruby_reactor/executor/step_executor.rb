# frozen_string_literal: true

module RubyReactor
  class Executor
    class StepExecutor
      def initialize(context, dependency_graph, retry_manager, result_handler, reactor_class, compensation_manager)
        @context = context
        @dependency_graph = dependency_graph
        @retry_manager = retry_manager
        @result_handler = result_handler
        @reactor_class = reactor_class
        @compensation_manager = compensation_manager
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
        puts "[EXECUTE_STEP] step: #{step_config.name}, async?: #{step_config.async?}, inline_async: #{@context.inline_async_execution}"

        if step_config.async? && !@context.inline_async_execution
          # Step-level async: hand off execution to worker
          puts "[ASYNC] Calling async router for #{step_config.name}"
          @context.current_step = step_config.name
          serialized_context = ContextSerializer.serialize(@context)

          result = configuration.async_router.perform_async(serialized_context, @reactor_class.name)
          puts "[ASYNC] Got result type: #{result.class}, is Executor?: #{result.is_a?(Executor)}"

          # Handle different result types from async router
          case result
          when RubyReactor::AsyncResult
            # Production behavior: return async result to caller
            puts "[ASYNC] Returning AsyncResult to caller"
            result
          when Executor
            # Worker executed inline and returned an executor
            # The worker has executed the current step via resume_execution
            # We need to merge the state back into our executor
            puts "[ASYNC] Calling merge_executor_state"
            
            # Get the step name before merging (as merge clears current_step)
            step_name = @context.current_step
            
            merge_executor_state(result)

            # Check if the async execution resulted in a failure
            if result.result.is_a?(RubyReactor::Failure)
              # Async execution failed - we need to rollback steps completed before the handoff
              @compensation_manager.rollback_completed_steps
              # Return the failure to stop execution
              result.result
            else
              # Handle the step result - use the result of the current step
              resolved_arguments = resolve_arguments(step_config)
              step_result_value = result.context.intermediate_results[step_name]
              @result_handler.handle_step_result(step_config, RubyReactor.Success(step_result_value), resolved_arguments)
              # Return nil to continue execution
              nil
            end
          else
            # Unexpected result type, treat as error
            raise Error::ValidationError.new(
              "Unexpected result type from async router: #{result.class}",
              context: @context
            )
          end
        elsif @reactor_class.async?
          execute_step_with_retry(step_config)
        else
          execute_step_sync_with_retry(step_config)
        end
      end

      def merge_executor_state(other_executor)
        # Merge the state from the async-executed executor back into ours
        # We need to update our context IN PLACE, not replace the reference,
        # because the Executor also holds a reference to the same context object

        puts "[MERGE] Current trace length: #{@context.execution_trace.length}"
        puts "[MERGE] Other executor trace length: #{other_executor.context.execution_trace.length}"
        puts "[MERGE] Other executor trace: #{other_executor.context.execution_trace.inspect}"

        # Update intermediate results
        other_executor.context.intermediate_results.each do |step_name, value|
          @context.set_result(step_name, value)
        end

        # Append execution trace from the async execution
        # The Worker's execution will have ALL steps including ones we already executed,
        # but we only want to add the NEW entries (from current_step onwards)
        current_trace_length = @context.execution_trace.length
        new_trace_entries = other_executor.context.execution_trace[current_trace_length..-1] || []
        puts "[MERGE] New trace entries to add: #{new_trace_entries.inspect}"
        @context.execution_trace.concat(new_trace_entries)
        puts "[MERGE] Final trace length: #{@context.execution_trace.length}"

        # Update retry context
        @context.retry_context = other_executor.context.retry_context

        # Clear current_step since we've completed it
        @context.current_step = nil

        # Update our dependency graph to reflect completed steps
        other_executor.context.intermediate_results.keys.each do |step_name|
          @dependency_graph.complete_step(step_name)
        end

        # Also mark the current_step as completed if it exists (for failed steps that don't have results)
        @dependency_graph.complete_step(other_executor.context.current_step) if other_executor.context.current_step

        # Merge any undo stack items
        other_executor.undo_stack.each do |item|
          # Avoid duplicates by checking if this step is already in the undo stack
          unless @compensation_manager.undo_stack.any? { |existing| existing[:step].name == item[:step].name }
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

        # For async reactors, handle results the same way as sync
        # Special async results (RetryQueuedResult, AsyncResult) are returned as-is
        unless result.is_a?(RetryQueuedResult) || result.is_a?(RubyReactor::AsyncResult)
          resolved_arguments = resolve_arguments(step_config)
          @result_handler.handle_step_result(step_config, result, resolved_arguments)
        end

        result
      end

      def execute_step_sync_with_retry(step_config)
        result = @retry_manager.execute_with_retry(step_config, @reactor_class) do
          safe_execute_step_sync(step_config)
        end

        # Now handle the result (success, failure, or max retries exhausted)
        # Only call handle_step_result if we're not dealing with special async results
        unless result.is_a?(RetryQueuedResult) || result.is_a?(RubyReactor::AsyncResult)
          resolved_arguments = resolve_arguments(step_config)
          @result_handler.handle_step_result(step_config, result, resolved_arguments)
        end

        result
      end

      def safe_execute_step_sync(step_config)
        execute_step_sync_without_result_handling(step_config)
      rescue StandardError => e
        RubyReactor::Failure(e)
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

          # Validate arguments if validator is defined
          validate_step_arguments(step_config, resolved_arguments)

          # Execute the step
          run_step_implementation(step_config, resolved_arguments)
        end
      end

      private

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
          step_config.run_block.call(arguments, @context)
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
    end
  end
end
