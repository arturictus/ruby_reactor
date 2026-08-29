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
      reactor = AsyncRetryMapReactorV2.new
      result = reactor.run(items: %w[hello world], fail_until_attempt: 3)

      expect(result).to be_a(RubyReactor::DispatchResult)

      # No batch_size now runs through the same per-element path as batch_size
      # maps (batch_size defaults to the full source size), so drain the element
      # and collector workers; retries requeue MapElementWorker jobs.
      RubyReactor::Adapters::Sidekiq::MapElementWorker.drain
      RubyReactor::Adapters::Sidekiq::MapCollectorWorker.drain

      # Retrieve final result
      context_id = reactor.context.context_id
      storage = RubyReactor.configuration.storage_adapter
      context = storage.retrieve_context(context_id, AsyncRetryMapReactorV2.name)

      result_data = context["intermediate_results"]["processed"]
      expect(result_data["_type"]).to eq("Map::ResultEnumerator")

      enumerator = RubyReactor::ContextSerializer.deserialize_value(result_data)
      expect(enumerator.to_a.map(&:value)).to eq(%w[HELLO WORLD])
    end

    it "fails after max retries in async mode" do
      reactor = AsyncRetryMapReactorV2.new
      result = reactor.run(items: %w[hello world], fail_until_attempt: 10)

      expect(result).to be_a(RubyReactor::DispatchResult)

      RubyReactor::Adapters::Sidekiq::MapElementWorker.drain
      RubyReactor::Adapters::Sidekiq::MapCollectorWorker.drain

      context_id = reactor.context.context_id
      storage = RubyReactor.configuration.storage_adapter
      context_data = storage.retrieve_context(context_id, AsyncRetryMapReactorV2.name)

      # With fail_fast (the default) the exhausted-retry failure propagates to the
      # parent reactor: the collector marks the parent context as failed.
      context = RubyReactor::Context.deserialize_from_retry(context_data)
      expect(context.status).to eq("failed")
      expect(context.failure_reason.error).to include("failed after 5 attempts")

      # The per-element error is also recorded in the stored map results.
      map_id = context_data["map_operations"]["processed"]
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
      reactor = AsyncBatchRetryMapReactorV2.new
      result = reactor.run(items: %w[hello world foo bar], fail_until_attempt: 3)

      expect(result).to be_a(RubyReactor::DispatchResult)

      # Drain workers (multiple times might be needed for batches/retries)
      RubyReactor::Adapters::Sidekiq::MapElementWorker.drain
      RubyReactor::Adapters::Sidekiq::MapCollectorWorker.drain

      # Retrieve final result
      context_id = reactor.context.context_id
      storage = RubyReactor.configuration.storage_adapter
      context = storage.retrieve_context(context_id, AsyncBatchRetryMapReactorV2.name)

      result_data = context["intermediate_results"]["processed"]
      expect(result_data).to be_a(Hash)
      expect(result_data["_type"]).to eq("Map::ResultEnumerator")

      enumerator = RubyReactor::ContextSerializer.deserialize_value(result_data)
      puts "ENUMERATOR: #{enumerator.class}"
      puts "ENUMERATOR DETAILS: #{enumerator.inspect}"
      results_array = enumerator.to_a
      puts "RESULTS ARRAY: #{results_array.inspect}"
      expect(results_array.map(&:value)).to eq(%w[HELLO WORLD FOO BAR])
    end

    it "respects batch_size during retries" do
      reactor = AsyncBatchRetryMapReactorV2.new
      result = reactor.run(items: %w[a b c d e], fail_until_attempt: 2)

      expect(result).to be_a(RubyReactor::DispatchResult)

      # Drain workers
      RubyReactor::Adapters::Sidekiq::MapElementWorker.drain
      RubyReactor::Adapters::Sidekiq::MapCollectorWorker.drain

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
            failed_count: failures.count,
            total: results.count
          }
        end
      end
    end

    it "retries all failing elements in async mode and collects results" do
      reactor = AsyncFailFastFalseRetryReactorV2.new
      result = reactor.run(
        items: %w[hello world foo bar],
        fail_items: %w[world bar],
        fail_until_attempt: 3
      )

      expect(result).to be_a(RubyReactor::DispatchResult)

      # Drain workers
      RubyReactor::Adapters::Sidekiq::MapElementWorker.drain
      RubyReactor::Adapters::Sidekiq::MapCollectorWorker.drain

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
      reactor = AsyncFailFastFalseRetryReactorV2.new
      result = reactor.run(
        items: %w[hello world foo bar],
        fail_items: %w[world bar],
        fail_until_attempt: 10 # Will exhaust retries
      )

      expect(result).to be_a(RubyReactor::DispatchResult)

      # Drain workers
      RubyReactor::Adapters::Sidekiq::MapElementWorker.drain
      RubyReactor::Adapters::Sidekiq::MapCollectorWorker.drain

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
