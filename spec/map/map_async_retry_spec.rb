# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Map Async Retry Behavior" do
  # ============================================================================
  # Test retry in async map execution (without batch_size)
  # ============================================================================

  describe "Retry in async map execution without batch_size" do
    class AsyncRetryItemReactor < RubyReactor::Reactor
      input :item
      input :fail_until

      step :process_with_retry do
        argument :val, input(:item)
        argument :fail_until, input(:fail_until)

        retries max_attempts: 5, backoff: :fixed, base_delay: 0

        run do |args, context|
          attempt = context.retry_context.attempts_for_step(:process_with_retry)

          if attempt < args[:fail_until]
            RubyReactor::Failure("Attempt #{attempt} failed")
          else
            RubyReactor::Success(args[:val].upcase)
          end
        end
      end

      returns :process_with_retry
    end

    class AsyncRetryMapReactorV2 < RubyReactor::Reactor
      input :items
      input :fail_until_attempt

      map :processed, AsyncRetryItemReactor do
        source input(:items)
        argument :item, element(:processed)
        argument :fail_until, input(:fail_until_attempt)

        async true
      end
    end

    it "retries failed elements in async mode" do
      allow(RubyReactor::Configuration.instance).to receive(:async_router).and_return(Support::WorkerMock)

      reactor = AsyncRetryMapReactorV2.new
      result = reactor.run(items: %w[hello world], fail_until_attempt: 3)

      expect(result).to be_a(RubyReactor::AsyncResult)

      # Drain workers to process elements and retries
      RubyReactor::SidekiqWorkers::MapExecutionWorker.drain
      RubyReactor::SidekiqWorkers::MapElementWorker.drain
      RubyReactor::SidekiqWorkers::MapCollectorWorker.drain

      # Retrieve final result
      context_id = reactor.context.context_id
      storage = RubyReactor.configuration.storage_adapter
      context = storage.retrieve_context(context_id, AsyncRetryMapReactorV2.name)

      expect(context["intermediate_results"]["processed"]["value"]).to eq(%w[HELLO WORLD])
    end

    it "fails after max retries in async mode" do
      allow(RubyReactor::Configuration.instance).to receive(:async_router).and_return(Support::WorkerMock)

      reactor = AsyncRetryMapReactorV2.new
      result = reactor.run(items: %w[hello world], fail_until_attempt: 10)

      expect(result).to be_a(RubyReactor::AsyncResult)

      # Drain workers
      RubyReactor::SidekiqWorkers::MapExecutionWorker.drain
      RubyReactor::SidekiqWorkers::MapElementWorker.drain
      RubyReactor::SidekiqWorkers::MapCollectorWorker.drain

      # Retrieve final result (should be failure)
      # context_id = reactor.context.context_id
      # storage = RubyReactor.configuration.storage_adapter
      # context = storage.retrieve_context(context_id, AsyncRetryMapReactorV2.name)

      # The context might not have the error directly if it failed fast?
      # If fail_fast is true (default), the map result stored in intermediate_results might be missing or partial?
      # Or the reactor execution itself failed?
      # If the map failed, the collector would have marked the step as failed.
      # But we need to check how the failure is propagated.
      # For async map, the collector stores the result.

      # If fail_fast is true, the first failure triggers collection with error.
      # Let's check intermediate_results.
      # Wait, if map failed, the step "processed" failed.
      # The reactor result should be failure.
      # But we can't get reactor result easily from context?
      # We can check if the step "processed" is in intermediate_results?
      # Or check if there is an error in the context?

      # Actually, let's check if the collector job stored the failure.
      # The collector worker calls `Executor.resume_execution` or similar?
      # No, `MapCollectorWorker` calls `Map::Collector.collect`.
      # `Map::Collector` stores the result in `intermediate_results` or calls `resume_execution`.

      # If we want to check the final result of the reactor, we might need to look at how `AsyncRouter` handles the final result?
      # Usually, the final result is returned to the caller if sync, but here it's async.
      # The caller (us) only has the initial AsyncResult.

      # We can check the context state.
      # Or we can check if the map result in storage has errors.

      # Let's verify that the map result contains the error.
      # The collector should have processed it.

      # Check intermediate_results for "processed"
      # If it failed, it might not be there, or it might be a Failure object?
      # Context serialization handles Failure objects?

      # Let's assume the test wants to verify failure.
      # We can check that retries were exhausted.

      # Also, since we are using `WorkerMock`, maybe we can spy on it?
      # But `WorkerMock` just delegates to Sidekiq workers here.

      # Let's check the context for the error.
      # If the map step failed, the reactor execution failed.
      # The context might have `state: :failed`? (If such thing exists)

      # Let's just check that we got the expected failure in the map results storage if possible,
      # Retrieve final result (should be failure)
      context_id = reactor.context.context_id
      storage = RubyReactor.configuration.storage_adapter
      context_data = storage.retrieve_context(context_id, AsyncRetryMapReactorV2.name)

      expect(context_data["intermediate_results"]["processed"]["_type"]).to eq("Failure")
      expect(context_data["intermediate_results"]["processed"]["error"]).to include("failed after 5 attempts")

      # Get map_id from child_contexts in the stored context data
      # context_data["composed_contexts"] or similar?
      # Actually, map operations are stored in "map_operations" in context
      # Let's check context structure
      # context_data["map_operations"] should contain map_id
      # Let's check Context#map_operations usage.
      # It seems it stores map_id by step name.

      map_ops = context_data["map_operations"]

      map_id = map_ops["processed"]

      map_results = storage.retrieve_map_results(map_id, AsyncRetryMapReactorV2.name)
      errors = map_results.select { |v| v.is_a?(Hash) && v["_error"] }
      expect(errors).not_to be_empty
      expect(errors.first["_error"]).to include("failed after 5 attempts")
    end
  end

  # ============================================================================
  # Test retry in async map execution (with batch_size)
  # ============================================================================

  describe "Retry in async map execution with batch_size" do
    class AsyncBatchRetryItemReactor < RubyReactor::Reactor
      input :item
      input :fail_until

      step :process_with_retry do
        argument :val, input(:item)
        argument :fail_until, input(:fail_until)

        retries max_attempts: 5, backoff: :fixed, base_delay: 0

        run do |args, context|
          attempt = context.retry_context.attempts_for_step(:process_with_retry)

          if attempt < args[:fail_until]
            RubyReactor::Failure("Attempt #{attempt} failed")
          else
            RubyReactor::Success(args[:val].upcase)
          end
        end
      end

      returns :process_with_retry
    end

    class AsyncBatchRetryMapReactorV2 < RubyReactor::Reactor
      input :items
      input :fail_until_attempt

      map :processed, AsyncBatchRetryItemReactor do
        source input(:items)
        argument :item, element(:processed)
        argument :fail_until, input(:fail_until_attempt)

        async true, batch_size: 2
      end
    end

    it "retries failed elements with batch_size" do
      allow(RubyReactor::Configuration.instance).to receive(:async_router).and_return(Support::WorkerMock)

      reactor = AsyncBatchRetryMapReactorV2.new
      result = reactor.run(items: %w[hello world foo bar], fail_until_attempt: 3)

      expect(result).to be_a(RubyReactor::AsyncResult)

      # Drain workers (multiple times might be needed for batches/retries)
      RubyReactor::SidekiqWorkers::MapElementWorker.drain
      RubyReactor::SidekiqWorkers::MapCollectorWorker.drain

      # Retrieve final result
      context_id = reactor.context.context_id
      storage = RubyReactor.configuration.storage_adapter
      context = storage.retrieve_context(context_id, AsyncBatchRetryMapReactorV2.name)

      expect(context["intermediate_results"]["processed"]).to eq(%w[HELLO WORLD FOO BAR])
    end

    it "respects batch_size during retries" do
      allow(RubyReactor::Configuration.instance).to receive(:async_router).and_return(Support::WorkerMock)

      reactor = AsyncBatchRetryMapReactorV2.new
      result = reactor.run(items: %w[a b c d e], fail_until_attempt: 2)

      expect(result).to be_a(RubyReactor::AsyncResult)

      # Drain workers
      RubyReactor::SidekiqWorkers::MapElementWorker.drain
      RubyReactor::SidekiqWorkers::MapCollectorWorker.drain

      # Retrieve final result
      context_id = reactor.context.context_id
      storage = RubyReactor.configuration.storage_adapter
      context = storage.retrieve_context(context_id, AsyncBatchRetryMapReactorV2.name)

      expect(context["intermediate_results"]["processed"].length).to eq(5)
    end
  end

  # ============================================================================
  # Test async retry with fail_fast: false
  # ============================================================================

  describe "Async retry with fail_fast: false" do
    class AsyncFailFastFalseItemReactor < RubyReactor::Reactor
      input :item
      input :fail_items
      input :fail_until

      step :process do
        argument :val, input(:item)
        argument :fail_items, input(:fail_items)
        argument :fail_until, input(:fail_until)

        retries max_attempts: 4, backoff: :fixed, base_delay: 0

        run do |args, context|
          if args[:fail_items].include?(args[:val])
            attempt = context.retry_context.attempts_for_step(:process)
            if attempt < args[:fail_until]
              RubyReactor::Failure("Item #{args[:val]} failed on attempt #{attempt}")
            else
              RubyReactor::Success(args[:val].upcase)
            end
          else
            RubyReactor::Success(args[:val].upcase)
          end
        end
      end

      returns :process
    end

    class AsyncFailFastFalseRetryReactorV2 < RubyReactor::Reactor
      input :items
      input :fail_items
      input :fail_until_attempt

      map :processed, AsyncFailFastFalseItemReactor do
        source input(:items)
        argument :item, element(:processed)
        argument :fail_items, input(:fail_items)
        argument :fail_until, input(:fail_until_attempt)

        async true, batch_size: 2
        fail_fast false

        collect do |results|
          successes = results.select(&:success?).map(&:value)
          failures = results.select(&:failure?)

          {
            successful: successes,
            failed_count: failures.length,
            total: results.length
          }
        end
      end
    end

    it "retries all failing elements in async mode and collects results" do
      allow(RubyReactor::Configuration.instance).to receive(:async_router).and_return(Support::WorkerMock)

      reactor = AsyncFailFastFalseRetryReactorV2.new
      result = reactor.run(
        items: %w[hello world foo bar],
        fail_items: %w[world bar],
        fail_until_attempt: 3
      )

      expect(result).to be_a(RubyReactor::AsyncResult)

      # Drain workers
      RubyReactor::SidekiqWorkers::MapElementWorker.drain
      RubyReactor::SidekiqWorkers::MapCollectorWorker.drain

      # Retrieve final result
      context_id = reactor.context.context_id
      storage = RubyReactor.configuration.storage_adapter
      context = storage.retrieve_context(context_id, AsyncFailFastFalseRetryReactorV2.name)

      collected = context["intermediate_results"]["processed"]
      expect(collected["successful"]).to eq(%w[HELLO WORLD FOO BAR])
      expect(collected["failed_count"]).to eq(0)
      expect(collected["total"]).to eq(4)
    end

    it "collects partial successes when some async retries are exhausted" do
      allow(RubyReactor::Configuration.instance).to receive(:async_router).and_return(Support::WorkerMock)

      reactor = AsyncFailFastFalseRetryReactorV2.new
      result = reactor.run(
        items: %w[hello world foo bar],
        fail_items: %w[world bar],
        fail_until_attempt: 10 # Will exhaust retries
      )

      expect(result).to be_a(RubyReactor::AsyncResult)

      # Drain workers
      RubyReactor::SidekiqWorkers::MapElementWorker.drain
      RubyReactor::SidekiqWorkers::MapCollectorWorker.drain

      # Retrieve final result
      context_id = reactor.context.context_id
      storage = RubyReactor.configuration.storage_adapter
      context = storage.retrieve_context(context_id, AsyncFailFastFalseRetryReactorV2.name)

      collected = context["intermediate_results"]["processed"]
      expect(collected["successful"]).to eq(%w[HELLO FOO])
      expect(collected["failed_count"]).to eq(2)
      expect(collected["total"]).to eq(4)
    end
  end
end
