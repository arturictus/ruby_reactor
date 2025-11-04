# frozen_string_literal: true

module RubyReactor
  class Executor
    class StepExecutor
      def initialize(context, dependency_graph, retry_manager, result_handler, reactor_class)
        @context = context
        @dependency_graph = dependency_graph
        @retry_manager = retry_manager
        @result_handler = result_handler
        @reactor_class = reactor_class
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

            # If a step returns MaxRetriesExhaustedFailure, we need to stop and return it
            return result if result.is_a?(RubyReactor::MaxRetriesExhaustedFailure)
          end
        end

        # Return the final result
        @result_handler.final_result(@reactor_class)
      end

      def execute_step(step_config)
        if step_config.async?
          # Step-level async: hand off execution to worker
          @context.current_step = step_config.name
          serialized_context = ContextSerializer.serialize(@context)
          RubyReactor::Worker.perform_async(serialized_context, @reactor_class.name)
          RubyReactor::AsyncResult.new(job_id: nil) # TODO: Get job ID
        elsif @reactor_class.async?
          execute_step_with_retry(step_config)
        else
          execute_step_sync_with_retry(step_config)
        end
      end

      def execute_step_with_retry(step_config)
        @retry_manager.execute_with_retry(step_config, @reactor_class) do
          safe_execute_step_sync(step_config)
        end
      end

      def execute_step_sync_with_retry(step_config)
        @retry_manager.execute_with_retry(step_config, @reactor_class) do
          safe_execute_step_sync(step_config)
        end
      end

      def safe_execute_step_sync(step_config)
        execute_step_sync(step_config)
      rescue StandardError => e
        RubyReactor::Failure(e)
      end

      def execute_step_sync(step_config)
        @context.with_step(step_config.name) do
          # Check conditions and guards
          unless step_config.should_run?(@context)
            @dependency_graph.complete_step(step_config.name)
            return
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

      private

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
