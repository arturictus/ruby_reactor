# frozen_string_literal: true

require "spec_helper"

# This test suite recreates the Elixir Reactor data pipeline example to verify feature parity
# Reference: https://github.com/ash-project/reactor/blob/main/documentation/how-to/data-pipelines.md
#
# FEATURE PARITY NOTES:
# ✅ Implemented: map steps, batch_size, strict_ordering, collect, async execution, compose, retry
# ⚠️  Design Difference: Async handled via Sidekiq (Ruby) vs native Elixir concurrency
# ⚠️  Design Difference: No Iterex equivalent - using standard Ruby Enumerables
# ❌ Not Yet Implemented: Telemetry integration, progress tracking
# ❌ Not Applicable: Elixir-specific features like resumable iteration with checkpoints

RSpec.describe "Data Pipeline - Feature Parity with Elixir" do
  # ============================================================================
  # HELPER MODULE - Simulating external services
  # ============================================================================

  # Moved to spec/support/data_pipeline_definitions.rb
  # - DataPipelineHelpers
  # - ExtractCSVStep
  # - DataQualityCheckStep
  # - LoadToDatabaseStep
  # - LoadToSearchIndexStep
  # - GenerateProcessingReportStep
  # - UserETLReactor

  # ============================================================================
  # TESTS - Basic ETL Pipeline
  # ============================================================================

  describe "Complete ETL Pipeline" do
    let(:sample_users) do
      [
        { "id" => "1", "email" => "alice@example.com", "name" => "Alice Smith", "phone" => "+1-555-0100",
          "age" => "30" },
        { "id" => "2", "email" => "verified@example.com", "name" => "Bob Jones", "phone" => "555-0200", "age" => "25" },
        { "id" => "3", "email" => "charlie@example.com", "name" => "Charlie Brown", "phone" => "", "age" => "35" }
      ]
    end

    it "executes complete ETL pipeline with inline execution" do
      # Create reactor instance to access context
      subject = test_reactor(UserETLReactor, {
                               source_file: "/tmp/users.csv",
                               csv_data: sample_users,
                               output_destinations: %w[database search]
                             })

      expect(subject).to be_success

      # The reactor returns :generate_report, so result.value is the report directly
      report = subject.result.value
      expect(report).not_to be_nil
      expect(report[:successful_count]).to eq(3)
      expect(report[:failed_count]).to eq(0)
      expect(report[:success_rate]).to eq(1.0)
      expect(report[:source_count]).to eq(3)

      # Access intermediate results from context
      context = subject.reactor_instance.context
      transformed = context.intermediate_results[:transform_users]
      expect(transformed).to be_an(Array)
      expect(transformed.length).to eq(3)

      # Verify first user was transformed correctly
      alice = transformed.find { |u| u[:email] == "alice@example.com" }
      expect(alice[:name]).to eq("Alice Smith")
      expect(alice[:phone]).to eq("+15550100")
      expect(alice[:age]).to eq(30)
      expect(alice[:verified]).to be(false)

      # Verify enrichment worked
      bob = transformed.find { |u| u[:email] == "verified@example.com" }
      expect(bob[:verified]).to be(true)
      expect(bob[:company]).to eq("Acme Corp")
      expect(bob[:location]).to eq("San Francisco")

      # Verify loading results
      expect(context.intermediate_results[:load_to_database][:inserted]).to eq(3)
      expect(context.intermediate_results[:load_to_search_index][:indexed]).to eq(3)
    end
  end

  # ============================================================================
  # TESTS - Map Features: batch_size and strict_ordering
  # ============================================================================

  describe "Map Features: batch_size and strict_ordering" do
    class SimpleTransformReactor < RubyReactor::Reactor
      input :numbers

      map :doubled_numbers do
        source input(:numbers)
        argument :number, element(:doubled_numbers)

        # FEATURE: batch_size controls how many elements are processed in parallel
        # FEATURE: strict_ordering controls whether results maintain input order
        batch_size 2
        strict_ordering true

        step :double do
          argument :val, input(:number)
          run { |args, _| RubyReactor::Success(args[:val] * 2) }
        end

        returns :double
      end
    end

    it "processes elements with batch_size and strict_ordering in inline mode" do
      result = SimpleTransformReactor.run(numbers: [1, 2, 3, 4, 5])

      expect(result).to be_a(RubyReactor::Success)
      expect(result.value[:doubled_numbers]).to eq([2, 4, 6, 8, 10])
    end

    class UnorderedMapReactor < RubyReactor::Reactor
      input :numbers

      map :processed do
        source input(:numbers)
        argument :number, element(:processed)

        # FEATURE: strict_ordering false allows results in any order (optimization)
        strict_ordering false

        step :process do
          argument :val, input(:number)
          run { |args, _| RubyReactor::Success(args[:val] * 3) }
        end

        returns :process
      end
    end

    it "processes elements without strict ordering requirement" do
      result = UnorderedMapReactor.run(numbers: [1, 2, 3])

      expect(result).to be_a(RubyReactor::Success)
      # Results should still be correct, just potentially in different order
      # In inline mode, order is preserved anyway
      expect(result.value[:processed].sort).to eq([3, 6, 9])
    end
  end

  # ============================================================================
  # TESTS - Map Features: collect block
  # ============================================================================

  describe "Map Features: collect block for aggregation" do
    class AggregationReactor < RubyReactor::Reactor
      input :sales_data

      # FEATURE: collect block transforms the array of results
      map :regional_totals do
        source input(:sales_data)
        argument :region_data, element(:regional_totals)

        step :sum_by_region do
          argument :data, input(:region_data)

          run do |args, _|
            region = args[:data][:region]
            total = args[:data][:sales].sum
            RubyReactor::Success({ region: region, total: total })
          end
        end

        returns :sum_by_region

        # FEATURE: collect block aggregates all results
        collect do |results|
          grand_total = results.sum { |r| r[:total] }
          { grand_total: grand_total, by_region: results }
        end
      end
    end

    it "aggregates results using collect block" do
      sales_data = [
        { region: "North", sales: [100, 200, 150] },
        { region: "South", sales: [300, 250] },
        { region: "East", sales: [175, 225, 300] }
      ]

      result = AggregationReactor.run(sales_data: sales_data)

      expect(result).to be_a(RubyReactor::Success)

      aggregated = result.value[:regional_totals]
      expect(aggregated[:grand_total]).to eq(1700)
      expect(aggregated[:by_region].length).to eq(3)
      expect(aggregated[:by_region][0]).to eq({ region: "North", total: 450 })
      expect(aggregated[:by_region][1]).to eq({ region: "South", total: 550 })
      expect(aggregated[:by_region][2]).to eq({ region: "East", total: 700 })
    end
  end

  # ============================================================================
  # TESTS - Error Handling in Map
  # ============================================================================

  describe "Error Handling in Map Steps" do
    class ErrorHandlingReactor < RubyReactor::Reactor
      input :items

      map :processed_items do
        source input(:items)
        argument :item, element(:processed_items)

        step :process_item do
          argument :val, input(:item)

          run do |args, _|
            # Simulate error on specific value
            if args[:val] == "error"
              RubyReactor::Failure("Processing failed for item")
            else
              RubyReactor::Success(args[:val].upcase)
            end
          end
        end

        returns :process_item
      end
    end

    it "handles errors in map processing" do
      result = ErrorHandlingReactor.run(items: %w[hello error world])

      # In inline mode, first error stops execution
      expect(result).to be_a(RubyReactor::Failure)
      expect(result.error).to include("Processing failed for item")
    end

    it "successfully processes all valid items" do
      result = ErrorHandlingReactor.run(items: %w[hello world])

      expect(result).to be_a(RubyReactor::Success)
      expect(result.value[:processed_items]).to eq(%w[HELLO WORLD])
    end
  end

  # ============================================================================
  # TESTS - Async Execution with Map
  # ============================================================================

  describe "Async Execution with Map" do
    class AsyncMapReactor < RubyReactor::Reactor
      input :numbers

      map :async_doubled do
        source input(:numbers)
        argument :number, element(:async_doubled)

        # FEATURE: async true sends processing to Sidekiq background jobs
        # DESIGN DIFFERENCE: Ruby uses Sidekiq vs Elixir's native async
        async true, batch_size: 2

        step :double do
          argument :val, input(:number)
          run { |args, _| RubyReactor::Success(args[:val] * 2) }
        end

        returns :double
      end
    end

    before do
      allow(RubyReactor.configuration).to receive(:async_router).and_return(RubyReactor::Adapters::Sidekiq::Router)
      Sidekiq::Testing.fake!
    end

    after do
      Sidekiq::Testing.inline!
    end

    it "queues async map execution with batch_size" do
      result = AsyncMapReactor.run(numbers: [1, 2, 3, 4, 5])

      # Should return DispatchResult because it went async
      expect(result).to be_a(RubyReactor::DispatchResult)

      # With batch_size: 2, should queue 2 jobs initially
      expect(RubyReactor::Adapters::Sidekiq::MapElementWorker.jobs.size).to eq(2)
    end
  end

  # ============================================================================
  # FEATURE PARITY DOCUMENTATION
  # ============================================================================

  describe "Feature Parity Documentation" do
    it "documents implemented features" do
      implemented_features = {
        map_steps: "✅ Map step with inline and class-based reactors",
        batch_size: "✅ batch_size option for controlling parallel execution",
        strict_ordering: "✅ strict_ordering option for ordered/unordered processing",
        collect: "✅ collect block for result aggregation",
        async_execution: "✅ Async execution via Sidekiq",
        compose: "✅ Compose for nested reactors",
        retry: "✅ Retry configuration per step",
        compensation: "✅ Compensation/undo blocks for error handling",
        dag_execution: "✅ DAG-based dependency resolution"
      }

      design_differences = {
        async: "⚠️  Ruby uses Sidekiq background jobs vs Elixir's native async/await",
        streaming: "⚠️  Ruby uses standard Enumerables vs Elixir's Iterex for streaming",
        resumable: "⚠️  Resumable processing via Sidekiq retry vs Elixir's checkpoint system"
      }

      missing_features = {
        telemetry: "❌ Telemetry integration not yet implemented",
        progress_tracking: "❌ Progress tracking not yet implemented",
        iterex_streaming: "❌ Iterex-style resumable iteration (Elixir-specific)"
      }

      # This test serves as documentation
      expect(implemented_features.keys.length).to be > 0
      expect(design_differences.keys.length).to be > 0
      expect(missing_features.keys.length).to be > 0
    end
  end
end
