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

        if step_config.async? && !@context.inline_async_execution
          # Step-level async: hand off execution to worker

          @context.current_step = step_config.name
          @context.undo_stack = @compensation_manager.undo_stack
          serialized_context = ContextSerializer.serialize(@context)

          result = configuration.async_router.perform_async(serialized_context, @reactor_class.name)

          # Handle different result types from async router
          case result
          when RubyReactor::AsyncResult
            # Production behavior: return async result to caller

            result
          when Executor
            # Worker executed inline and returned an executor
            # The worker has executed the current step and potentially remaining steps via resume_execution
            # We need to merge the state back into our executor

            merge_executor_state(result)

            result.result
          else
            # Unexpected result type, treat as error
            raise Error::ValidationError.new(
              "Unexpected result type from async router: #{result.class}",
              context: @context
            )
          end
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
    end
  end
end
