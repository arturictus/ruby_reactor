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

      def should_check_inline_completion?
        return true if defined?(Sidekiq::Testing) && Sidekiq::Testing.inline?

        false
      end
    end
  end
end

# Apply the patch automatically when this file is required
RubyReactor::Executor::StepExecutor.prepend(RubyReactor::RSpec::StepExecutorTestPatch)
