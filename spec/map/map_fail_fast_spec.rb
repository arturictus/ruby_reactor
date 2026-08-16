# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Map fail_fast Option" do
  # ============================================================================
  # Test fail_fast: true (default behavior - stop on first error)
  # ============================================================================

  describe "fail_fast: true (default)" do
    class FailFastTrueReactor < RubyReactor::Reactor
      input :items

      map :processed do
        source input(:items)
        argument :item, element(:processed)
        # fail_fast true is the default, no need to specify

        step :process do
          argument :val, input(:item)
          run do |args, _|
            if args[:val] == "error"
              RubyReactor::Failure("Failed: #{args[:val]}")
            else
              RubyReactor::Success(args[:val].upcase)
            end
          end
        end

        returns :process
      end
    end

    it "stops on first error and returns Failure" do
      result = FailFastTrueReactor.run(items: %w[hello error world])

      expect(result).to be_a(RubyReactor::Failure)
      expect(result.error).to include("Failed: error")
    end

    it "processes all items successfully when no errors" do
      result = FailFastTrueReactor.run(items: %w[hello world])

      expect(result).to be_a(RubyReactor::Success)
      expect(result.value[:processed]).to eq(%w[HELLO WORLD])
    end
  end

  # ============================================================================
  # Test fail_fast: false (continue on errors, collect partial results)
  # ============================================================================

  describe "fail_fast: false" do
    class FailFastFalseReactor < RubyReactor::Reactor
      input :items

      map :processed do
        source input(:items)
        argument :item, element(:processed)
        fail_fast false

        step :process do
          argument :val, input(:item)
          run do |args, _|
            if args[:val] == "error"
              RubyReactor::Failure("Failed: #{args[:val]}")
            else
              RubyReactor::Success(args[:val].upcase)
            end
          end
        end

        returns :process
      end
    end

    it "processes all elements and returns all results (successes and failures)" do
      result = FailFastFalseReactor.run(items: %w[hello error world])

      expect(result).to be_a(RubyReactor::Success)
      # New behavior: returns all Result objects so errors aren't swallowed silently
      results = result.value[:processed]
      expect(results.length).to eq(3)
      expect(results[0]).to be_a(RubyReactor::Success)
      expect(results[0].value).to eq("HELLO")
      expect(results[1]).to be_a(RubyReactor::Failure)
      expect(results[1].error).to include("Failed: error")
      expect(results[2]).to be_a(RubyReactor::Success)
      expect(results[2].value).to eq("WORLD")
    end

    it "processes all items successfully when no errors" do
      result = FailFastFalseReactor.run(items: %w[hello world])

      expect(result).to be_a(RubyReactor::Success)
      expect(result).to be_a(RubyReactor::Success)
      # When all succeed, we get an array of Success objects (implied by Result wrapper logic in map_step)
      # Wait, inline map with fail_fast: false returns [Result, Result].
      # We need to unwrap them if we want to check values easily, or just check the objects.
      results = result.value[:processed]
      expect(results.map(&:value)).to eq(%w[HELLO WORLD])
    end
  end

  # ============================================================================
  # Test fail_fast: false with collect block (access to both successes and failures)
  # ============================================================================

  describe "fail_fast: false with collect block" do
    class PartialFailureWithCollectReactor < RubyReactor::Reactor
      input :items

      map :processed do
        source input(:items)
        argument :item, element(:processed)
        fail_fast false

        step :process do
          argument :val, input(:item)
          run do |args, _|
            if args[:val].start_with?("error")
              RubyReactor::Failure("Failed: #{args[:val]}")
            else
              RubyReactor::Success(args[:val].upcase)
            end
          end
        end

        returns :process

        # Collect block receives Result objects when fail_fast: false
        collect do |results|
          successes = results.select(&:success?).map(&:value)
          failures = results.select(&:failure?).map(&:error)

          {
            successful: successes,
            failed: failures,
            total: results.length,
            success_rate: successes.length.to_f / results.length
          }
        end
      end
    end

    it "collects both successes and failures" do
      result = PartialFailureWithCollectReactor.run(items: %w[hello error1 world error2 foo])

      expect(result).to be_a(RubyReactor::Success)

      collected = result.value[:processed]
      expect(collected[:successful]).to eq(%w[HELLO WORLD FOO])
      # Error messages include retry wrapper
      expect(collected[:failed].length).to eq(2)
      expect(collected[:failed][0]).to include("Failed: error1")
      expect(collected[:failed][1]).to include("Failed: error2")
      expect(collected[:total]).to eq(5)
      expect(collected[:success_rate]).to eq(0.6)
    end

    it "handles all successes correctly" do
      result = PartialFailureWithCollectReactor.run(items: %w[hello world])

      expect(result).to be_a(RubyReactor::Success)

      collected = result.value[:processed]
      expect(collected[:successful]).to eq(%w[HELLO WORLD])
      expect(collected[:failed]).to eq([])
      expect(collected[:total]).to eq(2)
      expect(collected[:success_rate]).to eq(1.0)
    end

    it "handles all failures correctly" do
      result = PartialFailureWithCollectReactor.run(items: %w[error1 error2 error3])

      expect(result).to be_a(RubyReactor::Success)

      collected = result.value[:processed]
      expect(collected[:successful]).to eq([])
      # Error messages include retry wrapper
      expect(collected[:failed].length).to eq(3)
      expect(collected[:failed][0]).to include("Failed: error1")
      expect(collected[:failed][1]).to include("Failed: error2")
      expect(collected[:failed][2]).to include("Failed: error3")
      expect(collected[:total]).to eq(3)
      expect(collected[:success_rate]).to eq(0.0)
    end
  end

  # ============================================================================
  # Test explicit fail_fast: true with collect block
  # ============================================================================

  describe "fail_fast: true with collect block" do
    class FailFastTrueWithCollectReactor < RubyReactor::Reactor
      input :items

      map :processed do
        source input(:items)
        argument :item, element(:processed)
        fail_fast true

        step :process do
          argument :val, input(:item)
          run do |args, _|
            if args[:val] == "error"
              RubyReactor::Failure("Failed: #{args[:val]}")
            else
              RubyReactor::Success(args[:val].upcase)
            end
          end
        end

        returns :process

        # When fail_fast: true, collect receives values (not Result objects)
        collect do |results|
          {
            items: results,
            count: results.length
          }
        end
      end
    end

    it "stops on first error before collect is called" do
      result = FailFastTrueWithCollectReactor.run(items: %w[hello error world])

      # Should fail before collect is called
      expect(result).to be_a(RubyReactor::Failure)
      expect(result.error).to include("Failed: error")
    end

    it "calls collect with values when all succeed" do
      result = FailFastTrueWithCollectReactor.run(items: %w[hello world])

      expect(result).to be_a(RubyReactor::Success)

      collected = result.value[:processed]
      expect(collected[:items]).to eq(%w[HELLO WORLD])
      expect(collected[:count]).to eq(2)
    end
  end

  # ============================================================================
  # Test complex ETL scenario with fail_fast: false
  # ============================================================================

  describe "ETL scenario with partial failures" do
    class ETLWithPartialFailuresReactor < RubyReactor::Reactor
      input :records

      map :validated_records do
        source input(:records)
        argument :record, element(:validated_records)
        fail_fast false

        step :validate do
          argument :rec, input(:record)
          run do |args, _|
            record = args[:rec]
            errors = []

            errors << "Missing name" if record[:name].nil? || record[:name].empty?
            errors << "Invalid email" unless record[:email]&.include?("@")
            errors << "Age out of range" if record[:age] && (record[:age] < 0 || record[:age] > 150)

            if errors.empty?
              RubyReactor::Success(record)
            else
              RubyReactor::Failure("Validation failed: #{errors.join(", ")}")
            end
          end
        end

        returns :validate

        collect do |results|
          valid = results.select(&:success?).map(&:value)
          invalid = results.select(&:failure?).map do |failure|
            { error: failure.error }
          end

          {
            valid_records: valid,
            invalid_records: invalid,
            valid_count: valid.length,
            invalid_count: invalid.length
          }
        end
      end
    end

    it "processes all records and separates valid from invalid" do
      records = [
        { name: "Alice", email: "alice@example.com", age: 30 },
        { name: "", email: "invalid", age: 25 }, # Missing name, invalid email
        { name: "Bob", email: "bob@example.com", age: 200 }, # Age out of range
        { name: "Charlie", email: "charlie@example.com", age: 35 }
      ]

      result = ETLWithPartialFailuresReactor.run(records: records)

      expect(result).to be_a(RubyReactor::Success)

      collected = result.value[:validated_records]
      expect(collected[:valid_count]).to eq(2)
      expect(collected[:invalid_count]).to eq(2)

      expect(collected[:valid_records].map { |r| r[:name] }).to eq(%w[Alice Charlie])

      expect(collected[:invalid_records][0][:error]).to include("Missing name")
      expect(collected[:invalid_records][0][:error]).to include("Invalid email")
      expect(collected[:invalid_records][1][:error]).to include("Age out of range")
    end
  end

  # ============================================================================
  # Test reproduction of Async Map Fail Fast Hang
  # ============================================================================

  describe "Reproduction of Async Map Fail Fast Hang" do
    class AsyncFailFastReactor < RubyReactor::Reactor
      input :items
      input :fail_item

      map :processed do
        source input(:items)
        argument :item, element(:processed)
        argument :fail_item, input(:fail_item)

        # Default fail_fast is true
        async true, batch_size: 2

        step :process do
          argument :val, input(:item)
          argument :fail_val, input(:fail_item)

          run do |args|
            if args[:val] == args[:fail_val]
              RubyReactor::Failure("Simulated failure for #{args[:val]}")
            else
              RubyReactor::Success(args[:val] * 2)
            end
          end
        end

        # No returns needed, map returns result of last step (or collection)
      end
    end

    it "fails the reactor when an item fails in async map with fail_fast: true" do
      # Manually create context and SAVE IT
      context = RubyReactor::Context.new(
        { items: [1, 2, 3, 4, 5], fail_item: 3 },
        AsyncFailFastReactor
      )

      # Save context manually to ensure it exists for Reactor.find
      storage = RubyReactor.configuration.storage_adapter
      serialized_ctx = RubyReactor::ContextSerializer.serialize(context)
      storage.store_context(context.context_id, serialized_ctx, AsyncFailFastReactor.name)

      # Trigger execution via async router
      # This mimics Reactor#run for async reactors (but we do it manually to ensure context persistence
      # and ID availability)
      RubyReactor.configuration.async_router.perform_async(context.context_id, AsyncFailFastReactor.name)

      # Drain Sidekiq jobs
      # We need to drain multiple times/types because:
      # 1. MapElementWorker executes the individual elements
      # 2. MapCollectorWorker waits for results

      # Main Worker
      RubyReactor::Adapters::Sidekiq::Worker.drain

      # Process elements (Batches)
      RubyReactor::Adapters::Sidekiq::MapElementWorker.drain

      # Collector
      RubyReactor::Adapters::Sidekiq::MapCollectorWorker.drain

      # Reload reactor from storage to check status
      stored_reactor = AsyncFailFastReactor.find(context.context_id)

      # If bug exists, status will be 'running' because Collector is waiting for all 5 results,
      # but only 1-4 might have run (3 failed), and 5 was skipped due to fail_fast check in Execution.

      expect(stored_reactor.context.status).to eq("failed")
      expect(stored_reactor.context.failure_reason.error).to include("Simulated failure for 3")
    end
  end
end
