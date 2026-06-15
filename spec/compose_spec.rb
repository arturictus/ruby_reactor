# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Compose" do
  class TestComposeReactor < RubyReactor::Reactor
    input :id

    step :validate_id do
      argument :id, input(:id)
      run { |args, _context| RubyReactor::Success(args[:id]) }
    end

    # We want to support this syntax:
    # compose :update_user_profile do
    #   async true
    #   argument :id, result(:validate_id)
    #   step :get_linkedin do ... end
    # end
    #
    # But currently ComposeBuilder expects a class.
    # So we will try to use the existing syntax first to see behavior,
    # or mock the new syntax if we want to TDD the new feature.
    # The user wants us to implement the new syntax AND the behavior.

    # Let's define the composed reactor separately for now to test current behavior
    class UserProfileReactor < RubyReactor::Reactor
      input :id

      step :get_linkedin do
        argument :id, input(:id)
        retries max_attempts: 3
        run do |args, _context|
          raise "Failed to get linkedin" if args[:id] == "fail"

          RubyReactor::Success({ profile: "linkedin_profile" })
        end
      end
    end

    compose :update_user_profile, UserProfileReactor do
      argument :id, result(:validate_id)
    end
  end

  it "retries the specific step inside composed reactor using inline syntax" do
    # We need to mock the async router to capture what gets enqueued
    queue = []
    allow(RubyReactor.configuration.async_router).to receive(:perform_async) do |context_id, reactor_name|
      queue << { context_id: context_id, reactor: reactor_name }
      RubyReactor::AsyncResult.new(job_id: "job_id")
    end

    allow(RubyReactor.configuration.async_router).to receive(:perform_in) do |delay, context_id, reactor_name|
      queue << { context_id: context_id, reactor: reactor_name, delay: delay }
      "job_id"
    end

    # Identity-only payload: rehydrate the root from storage by the enqueued id.
    storage = RubyReactor.configuration.storage_adapter
    rehydrate = lambda do |job|
      RubyReactor::ContextSerializer.deserialize_hash(storage.retrieve_context(job[:context_id], job[:reactor]))
    end

    class InlineComposeReactor < RubyReactor::Reactor
      input :id

      step :validate_id do
        argument :id, input(:id)
        run { |args| RubyReactor::Success(args[:id]) }
      end

      compose :update_user_profile do
        async true
        argument :id, result(:validate_id)

        step :get_linkedin do
          argument :id, input(:id)
          retries max_attempts: 3
          run do |args, _context|
            raise "Failed to get linkedin" if args[:id] == "fail"

            RubyReactor::Success({ profile: "linkedin_profile" })
          end
        end
      end
    end

    # Execute
    result = InlineComposeReactor.run(id: "fail")

    # It should return AsyncResult because compose is async
    expect(result).to be_a(RubyReactor::AsyncResult)

    # Check what was enqueued
    expect(queue.size).to eq(1)
    job = queue.first

    # The enqueued job should be for InlineComposeReactor (the root)
    # NOT the inner reactor, because we want to preserve the full tree
    context = rehydrate.call(job)
    expect(context.reactor_class).to eq(InlineComposeReactor)
    expect(context.inputs[:id]).to eq("fail")

    # Now simulate the worker running this job
    # It should execute the composed step, which fails and retries

    # We need to manually run what the worker would do
    context.inline_async_execution = true
    worker_executor = RubyReactor::Executor.new(context.reactor_class, {}, context)

    # We expect it to return a RetryQueuedResult or AsyncResult depending on how retry is handled
    # Since it's async retry, it should requeue and return RetryQueuedResult (or nil if handled internally)

    # Actually, `Executor#resume_execution` catches the retry and returns the result.
    # The `RetryManager` requeues the job.

    worker_executor.resume_execution

    # The result of the executor should be the result of the step that was executed.
    # Since it failed and requeued, it should be a RetryQueuedResult?
    # Or if it's async retry, `execute_step_with_retry` returns `RetryQueuedResult`.

    # Let's check the queue again. It should have the retry job.
    expect(queue.size).to eq(2)
    retry_job = queue.last

    # The retry job should ALSO be for InlineComposeReactor (the root)
    retry_context = rehydrate.call(retry_job)
    expect(retry_context.reactor_class).to eq(InlineComposeReactor)

    # And it should have the retry state for the inner step
    # The inner step is inside the composed reactor.
    # So we need to look into the private_data of the root context to find the child context.

    # The child context is stored in composed_contexts under the step name
    # Keys are symbolized during deserialization
    composed_data = retry_context.composed_contexts[:update_user_profile]
    expect(composed_data).not_to be_nil
    expect(composed_data[:type]).to eq(:composed) # JSON serialization might make it string

    child_context = composed_data[:context]
    expect(child_context).to be_a(RubyReactor::Context)

    # The child context should have the retry state
    expect(child_context.retry_context.attempts_for_step(:get_linkedin)).to eq(1)
  end
end
