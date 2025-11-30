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

    it "processes all elements and returns only successful values by default" do
      result = FailFastFalseReactor.run(items: %w[hello error world])

      expect(result).to be_a(RubyReactor::Success)
      # Default behavior: only successful values are returned
      expect(result.value[:processed]).to eq(%w[HELLO WORLD])
    end

    it "processes all items successfully when no errors" do
      result = FailFastFalseReactor.run(items: %w[hello world])

      expect(result).to be_a(RubyReactor::Success)
      expect(result.value[:processed]).to eq(%w[HELLO WORLD])
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
end
