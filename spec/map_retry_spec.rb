# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Map Retry Behavior" do
  # ============================================================================
  # Test retry in inline map execution (step-level retry)
  # ============================================================================

  describe "Retry in inline map execution" do
    class RetryableMapReactor < RubyReactor::Reactor
      input :items
      input :fail_until_attempt

      map :processed do
        source input(:items)
        argument :item, element(:processed)
        argument :fail_until, input(:fail_until_attempt)

        step :process_with_retry do
          argument :val, input(:item)
          argument :fail_until, input(:fail_until)

          # Retry configuration is at STEP level, not map level
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
    end

    it "retries failed elements until success" do
      result = RetryableMapReactor.run(items: %w[hello world], fail_until_attempt: 3)

      expect(result).to be_a(RubyReactor::Success)
      expect(result.value[:processed]).to eq(%w[HELLO WORLD])
    end

    it "fails after max retries are exhausted" do
      result = RetryableMapReactor.run(items: %w[hello world], fail_until_attempt: 10)

      expect(result).to be_a(RubyReactor::Failure)
      expect(result.error).to include("failed after 5 attempts")
    end
  end

  # ============================================================================
  # Test retry with fail_fast: true
  # ============================================================================

  describe "Retry with fail_fast: true" do
    class RetryFailFastTrueReactor < RubyReactor::Reactor
      input :items
      input :fail_item
      input :fail_until_attempt

      map :processed do
        source input(:items)
        argument :item, element(:processed)
        argument :fail_item, input(:fail_item)
        argument :fail_until, input(:fail_until_attempt)

        fail_fast true

        step :process do
          argument :val, input(:item)
          argument :fail_item, input(:fail_item)
          argument :fail_until, input(:fail_until)

          retries max_attempts: 4, backoff: :fixed, base_delay: 0

          run do |args, context|
            if args[:val] == args[:fail_item]
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
    end

    it "retries failing element and succeeds" do
      result = RetryFailFastTrueReactor.run(
        items: %w[hello world foo],
        fail_item: "world",
        fail_until_attempt: 3
      )

      expect(result).to be_a(RubyReactor::Success)
      expect(result.value[:processed]).to eq(%w[HELLO WORLD FOO])
    end

    it "stops on first element after retries exhausted" do
      result = RetryFailFastTrueReactor.run(
        items: %w[hello world foo],
        fail_item: "world",
        fail_until_attempt: 10
      )

      expect(result).to be_a(RubyReactor::Failure)
      expect(result.error).to include("failed after 4 attempts")
      expect(result.error).to include("world")
    end
  end

  # ============================================================================
  # Test retry with fail_fast: false
  # ============================================================================

  describe "Retry with fail_fast: false" do
    class RetryFailFastFalseReactor < RubyReactor::Reactor
      input :items
      input :fail_items
      input :fail_until_attempt

      map :processed do
        source input(:items)
        argument :item, element(:processed)
        argument :fail_items, input(:fail_items)
        argument :fail_until, input(:fail_until_attempt)

        fail_fast false

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

    it "retries all failing elements and collects results" do
      result = RetryFailFastFalseReactor.run(
        items: %w[hello world foo bar],
        fail_items: %w[world bar],
        fail_until_attempt: 3
      )

      expect(result).to be_a(RubyReactor::Success)

      collected = result.value[:processed]
      expect(collected[:successful]).to eq(%w[HELLO WORLD FOO BAR])
      expect(collected[:failed_count]).to eq(0)
      expect(collected[:total]).to eq(4)
    end

    it "collects partial successes when some retries are exhausted" do
      result = RetryFailFastFalseReactor.run(
        items: %w[hello world foo bar],
        fail_items: %w[world bar],
        fail_until_attempt: 10 # Will exhaust retries
      )

      expect(result).to be_a(RubyReactor::Success)

      collected = result.value[:processed]
      expect(collected[:successful]).to eq(%w[HELLO FOO])
      expect(collected[:failed_count]).to eq(2)
      expect(collected[:total]).to eq(4)
    end
  end

  # ============================================================================
  # Test different retry backoff strategies
  # ============================================================================

  describe "Retry backoff strategies" do
    class ExponentialBackoffMapReactor < RubyReactor::Reactor
      input :items
      input :fail_until_attempt

      map :processed do
        source input(:items)
        argument :item, element(:processed)
        argument :fail_until, input(:fail_until_attempt)

        step :process do
          argument :val, input(:item)
          argument :fail_until, input(:fail_until)

          retries max_attempts: 5, backoff: :exponential, base_delay: 0

          run do |args, context|
            attempt = context.retry_context.attempts_for_step(:process)

            if attempt < args[:fail_until]
              RubyReactor::Failure("Attempt #{attempt}")
            else
              RubyReactor::Success(args[:val].upcase)
            end
          end
        end

        returns :process
      end
    end

    class LinearBackoffMapReactor < RubyReactor::Reactor
      input :items
      input :fail_until_attempt

      map :processed do
        source input(:items)
        argument :item, element(:processed)
        argument :fail_until, input(:fail_until_attempt)

        step :process do
          argument :val, input(:item)
          argument :fail_until, input(:fail_until)

          retries max_attempts: 5, backoff: :linear, base_delay: 0

          run do |args, context|
            attempt = context.retry_context.attempts_for_step(:process)

            if attempt < args[:fail_until]
              RubyReactor::Failure("Attempt #{attempt}")
            else
              RubyReactor::Success(args[:val].upcase)
            end
          end
        end

        returns :process
      end
    end

    it "succeeds with exponential backoff" do
      result = ExponentialBackoffMapReactor.run(items: %w[test], fail_until_attempt: 3)

      expect(result).to be_a(RubyReactor::Success)
      expect(result.value[:processed]).to eq(%w[TEST])
    end

    it "succeeds with linear backoff" do
      result = LinearBackoffMapReactor.run(items: %w[test], fail_until_attempt: 3)

      expect(result).to be_a(RubyReactor::Success)
      expect(result.value[:processed]).to eq(%w[TEST])
    end
  end

  # ============================================================================
  # Test retry context isolation between elements
  # ============================================================================

  describe "Retry context isolation" do
    class IsolatedRetryMapReactor < RubyReactor::Reactor
      input :items

      map :processed do
        source input(:items)
        argument :item, element(:processed)

        step :process do
          argument :val, input(:item)

          retries max_attempts: 3, backoff: :fixed, base_delay: 0

          run do |args, context|
            attempt = context.retry_context.attempts_for_step(:process)

            # First item fails twice, second item fails once
            fail_count = args[:val] == "first" ? 2 : 1

            if attempt <= fail_count
              RubyReactor::Failure("Attempt #{attempt}")
            else
              RubyReactor::Success("#{args[:val]}-#{attempt}")
            end
          end
        end

        returns :process
      end
    end

    it "maintains separate retry contexts for each element" do
      result = IsolatedRetryMapReactor.run(items: %w[first second])

      expect(result).to be_a(RubyReactor::Success)
      # First item succeeds on attempt 3, second on attempt 2
      expect(result.value[:processed]).to eq(%w[first-3 second-2])
    end
  end

  # ============================================================================
  # Test retry with complex transformations
  # ============================================================================

  describe "Retry with complex transformations" do
    class ComplexRetryMapReactor < RubyReactor::Reactor
      input :records

      map :validated do
        source input(:records)
        argument :record, element(:validated)

        fail_fast false

        step :validate do
          argument :rec, input(:record)

          retries max_attempts: 3, backoff: :fixed, base_delay: 0

          run do |args, context|
            record = args[:rec]
            attempt = context.retry_context.attempts_for_step(:validate)

            # Simulate transient validation errors
            if record[:simulate_transient_error] && attempt < 2
              RubyReactor::Failure("Transient validation error")
            elsif record[:name].nil? || record[:name].empty?
              RubyReactor::Failure("Missing name")
            else
              RubyReactor::Success(record.merge(validated_at_attempt: attempt))
            end
          end
        end

        returns :validate

        collect do |results|
          valid = results.select(&:success?).map(&:value)
          invalid = results.select(&:failure?)

          {
            valid_records: valid,
            invalid_count: invalid.length,
            total: results.length
          }
        end
      end
    end

    it "retries transient errors and succeeds" do
      records = [
        { name: "Alice", simulate_transient_error: true },
        { name: "Bob", simulate_transient_error: false },
        { name: "", simulate_transient_error: false } # Permanent error
      ]

      result = ComplexRetryMapReactor.run(records: records)

      expect(result).to be_a(RubyReactor::Success)

      collected = result.value[:validated]
      expect(collected[:valid_records].length).to eq(2)
      expect(collected[:invalid_count]).to eq(1)

      # Verify Alice was validated on attempt 2 (after retry)
      alice = collected[:valid_records].find { |r| r[:name] == "Alice" }
      expect(alice[:validated_at_attempt]).to eq(2)

      # Verify Bob was validated on attempt 1 (no retry needed)
      bob = collected[:valid_records].find { |r| r[:name] == "Bob" }
      expect(bob[:validated_at_attempt]).to eq(1)
    end
  end
end
