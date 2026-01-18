# frozen_string_literal: true

module RubyReactor
  module RSpec
    module Helpers
      def test_reactor(reactor_class, inputs: {}, context: {}, async: nil, process_jobs: true)
        TestSubject.new(
          reactor_class: reactor_class,
          inputs: inputs,
          context: context,
          async: async,
          process_jobs: process_jobs
        )
      end
    end

    # Patch StepExecutor to handle inline async execution during tests.
    # This allows tests to verify synchronous-like behavior with Sidekiq::Testing.inline!
    # without polluting the production StepExecutor code.
    module StepExecutorTestPatch
      def execute_step(step_config)
        # 1. Call original implementation
        result = super

        # 2. Add test-specific logic for inline async execution
        # Only interfere if we got an AsyncResult and we are in a testing environment that supports inline execution
        if (result.is_a?(RubyReactor::AsyncResult) || result.is_a?(RubyReactor::RetryQueuedResult)) && should_check_inline_completion?
          # Check if it finished or paused inline (e.g. Sidekiq::Testing.inline!)
          refresh_context_from_storage

          # If the step itself now has a result, it means it ran inline
          if @context.has_result?(step_config.name)
            # If the step failed, we should return failure
            return reconstruct_failure(@context.failure_reason) if @context.failed?

            return nil # Continue to next step
          end

          # If the overall reactor finished or paused for other reasons (e.g. error in worker)
          if @context.finished? || @context.status.to_s == "paused"
            return reconstruct_failure(@context.failure_reason) if @context.failed?

            if @context.status.to_s == "paused"
              return RubyReactor::InterruptResult.new(
                execution_id: @context.context_id,
                intermediate_results: @context.intermediate_results
              )
            end
            return nil # Finished successfully
          end
        elsif result.is_a?(RubyReactor::AsyncResult) == false && step_config.async? && !@context.inline_async_execution
          # Native Inline execution (e.g. WorkerMock returning non-AsyncResult)
          refresh_context_from_storage
          return result if result.is_a?(RubyReactor::Failure)
          return reconstruct_failure(@context.failure_reason) if @context.failed?

          return nil # Continue
        end

        # Return original result if no intervention needed
        result
      end

      private

      def refresh_context_from_storage
        storage = RubyReactor::Configuration.instance.storage_adapter
        reactor_class_name = @reactor_class.name
        serialized = storage.retrieve_context(@context.context_id, reactor_class_name)
        return unless serialized

        reloaded_context = Context.deserialize_from_retry(serialized)

        # Update local context state
        @context.status = reloaded_context.status
        @context.failure_reason = reloaded_context.failure_reason
        @context.cancelled = reloaded_context.cancelled
        @context.cancellation_reason = reloaded_context.cancellation_reason
        @context.intermediate_results.merge!(reloaded_context.intermediate_results)
        @context.execution_trace = reloaded_context.execution_trace
        @context.private_data.merge!(reloaded_context.private_data)
        @context.retry_context = reloaded_context.retry_context
        @context.composed_contexts.merge!(reloaded_context.composed_contexts)
        @context.map_operations.merge!(reloaded_context.map_operations)
        @context.map_metadata = reloaded_context.map_metadata

        # Also need to mark step as completed in dependency graph
        reloaded_context.intermediate_results.each_key do |step_name|
          @dependency_graph.complete_step(step_name.to_sym)
        end
      end

      private

      def should_check_inline_completion?
        return true if defined?(Sidekiq::Testing) && Sidekiq::Testing.inline?

        false
      end
    end
  end
end

# Apply the patch automatically when this file is required
RubyReactor::Executor::StepExecutor.prepend(RubyReactor::RSpec::StepExecutorTestPatch)
