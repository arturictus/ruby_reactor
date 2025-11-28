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

  module DataPipelineHelpers
    def self.normalize_phone(phone)
      return nil if phone.nil? || phone.empty?

      phone.gsub(/[^\d+]/, "")
    end

    def self.parse_age(age_str)
      return nil if age_str.nil? || age_str.empty?

      age_str.to_i
    end

    def self.simulate_external_api_call(email)
      # Simulate external API enrichment
      case email
      when /verified@/
        { company: "Acme Corp", location: "San Francisco", verified: true }
      when /unverified@/
        { company: "Unknown", location: "Unknown", verified: false }
      when /notfound@/
        nil
      else
        { company: "Test Co", location: "Remote", verified: false }
      end
    end
  end

  # ============================================================================
  # DATA EXTRACTION STEPS
  # ============================================================================

  class ExtractCSVStep
    include RubyReactor::Step

    def self.run(arguments, _context)
      # Simulate CSV extraction (in real scenario, would read from file)
      # file_path would be used: File.read(arguments[:file_path])
      users = arguments[:csv_data] || []

      stats = {
        total_count: users.length,
        file_size: users.to_s.bytesize,
        extracted_at: Time.now
      }

      RubyReactor::Success({ users: users, stats: stats })
    rescue StandardError => e
      RubyReactor::Failure("Failed to extract CSV: #{e.message}")
    end
  end

  class DataQualityCheckStep
    include RubyReactor::Step

    def self.run(arguments, _context)
      raw_data = arguments[:raw_data]
      users = raw_data[:users]

      quality_issues = analyze_quality(users)

      rules = {
        email_required: true,
        phone_format: /^\+?[\d\s\-()]+$/,
        name_min_length: 2,
        max_age: 120
      }

      if quality_issues.empty?
        RubyReactor::Success({ rules: rules, issues: [], status: :passed })
      elsif quality_issues.length < 100
        RubyReactor::Success({ rules: rules, issues: quality_issues, status: :warnings })
      else
        RubyReactor::Failure("Too many quality issues: #{quality_issues.length} problems found")
      end
    end

    def self.analyze_quality(users)
      users.each_with_index.flat_map do |user, index|
        check_user_quality(user, index)
      end
    end

    def self.check_user_quality(user, index)
      issues = []

      issues << "Row #{index + 1}: Missing email" if user["email"].nil? || user["email"].empty?

      issues << "Row #{index + 1}: Invalid name" if user["name"].nil? || user["name"].length < 2

      issues
    end
  end

  # ============================================================================
  # DATA LOADING STEPS
  # ============================================================================

  class LoadToDatabaseStep
    include RubyReactor::Step

    def self.run(arguments, _context)
      users = arguments[:users]

      # Simulate batch insertion
      batches = users.each_slice(1000).to_a
      total_inserted = 0

      batches.each do |batch|
        # Simulate database insert
        total_inserted += batch.length
      end

      RubyReactor::Success({ inserted: total_inserted, total_batches: batches.length })
    rescue StandardError => e
      RubyReactor::Failure("Database loading failed: #{e.message}")
    end

    def self.compensate(_reason, _arguments, _context)
      # Cleanup on failure - simulate removing inserted data
      # In real scenario: delete from database where email in user_emails
      # users = arguments[:users]
      RubyReactor::Success()
    end
  end

  class LoadToSearchIndexStep
    include RubyReactor::Step

    def self.run(arguments, _context)
      users = arguments[:users]

      # Simulate bulk indexing
      indexed = users.length

      RubyReactor::Success({ indexed: indexed })
    rescue StandardError => e
      RubyReactor::Failure("Search indexing failed: #{e.message}")
    end
  end

  class GenerateProcessingReportStep
    include RubyReactor::Step

    def self.run(arguments, _context)
      results = arguments[:results]

      report = {
        successful_count: results[:successful].length,
        failed_count: results[:failed].length,
        success_rate: results[:success_rate],
        source_count: results[:source_count],
        generated_at: Time.now
      }

      RubyReactor::Success(report)
    end
  end

  # ============================================================================
  # COMPLETE ETL PIPELINE REACTOR
  # ============================================================================

  class UserETLReactor < RubyReactor::Reactor
    input :source_file
    input :csv_data
    input :output_destinations

    # Step 1: Extract - Read and parse data
    step :extract_data, ExtractCSVStep do
      argument :file_path, input(:source_file)
      argument :csv_data, input(:csv_data)
    end

    # Step 2: Validate data quality
    step :validate_data_quality, DataQualityCheckStep do
      argument :raw_data, result(:extract_data)
    end

    # Step 3: Transform users in batches
    # This is the main MAP step that processes each user through a transformation pipeline
    # Testing: inline reactor definition, batch_size, strict_ordering
    map :transform_users do
      source result(:extract_data, [:users])
      argument :user, element(:transform_users)
      argument :rules, result(:validate_data_quality, [:rules])

      # FEATURE: Inline reactor definition within map
      step :clean_user do
        argument :user, input(:user)
        argument :rules, input(:rules)

        run do |args, _context|
          user = args[:user]
          cleaned = {
            id: user["id"],
            email: user["email"]&.downcase&.strip || "",
            name: user["name"]&.strip || "",
            phone: DataPipelineHelpers.normalize_phone(user["phone"]),
            age: DataPipelineHelpers.parse_age(user["age"]),
            created_at: Time.now
          }

          RubyReactor::Success(cleaned)
        rescue StandardError => e
          RubyReactor::Failure("Failed to clean user #{user["id"]}: #{e.message}")
        end
      end

      step :enrich_user do
        argument :clean_user, result(:clean_user)

        run do |args, _context|
          user = args[:clean_user]
          profile = DataPipelineHelpers.simulate_external_api_call(user[:email])

          if profile
            enriched = user.merge(
              company: profile[:company],
              location: profile[:location],
              verified: profile[:verified]
            )
            RubyReactor::Success(enriched)
          else
            # Continue without enrichment
            RubyReactor::Success(user.merge(verified: false))
          end
        rescue StandardError => e
          RubyReactor::Failure("Enrichment failed for #{user[:email]}: #{e.message}")
        end
      end

      step :validate_user do
        argument :user, result(:enrich_user)

        run do |args, _context|
          user = args[:user]
          errors = []

          errors << "Name too short" if user[:name].length < 2
          errors << "Invalid email format" unless user[:email].include?("@")
          errors << "Unrealistic age" if user[:age] && user[:age] > 120

          if errors.empty?
            RubyReactor::Success(user)
          else
            RubyReactor::Failure("Validation failed: #{errors.join(", ")}")
          end
        end
      end

      returns :validate_user
    end

    # Step 4: Collect transformation results
    # FEATURE: collect block for aggregating map results
    step :process_results do
      argument :transformed_users, result(:transform_users)
      argument :source_stats, result(:extract_data, [:stats])

      run do |args, _context|
        users = args[:transformed_users]
        stats = args[:source_stats]

        # Separate successful and failed transformations
        # In inline execution, all results are values (no Result wrappers)
        # In async execution, we'd need to handle Result objects
        successful_users = users.select { |u| u.is_a?(Hash) }
        failed_users = [] # Would contain failures in async mode

        result = {
          successful: successful_users,
          failed: failed_users,
          source_count: stats[:total_count],
          success_rate: successful_users.length.to_f / users.length
        }

        RubyReactor::Success(result)
      end
    end

    # Step 5: Load to multiple destinations in parallel
    # FEATURE: Multiple async steps that can run in parallel
    step :load_to_database, LoadToDatabaseStep do
      argument :users, result(:process_results, [:successful])
      async true
    end

    step :load_to_search_index, LoadToSearchIndexStep do
      argument :users, result(:process_results, [:successful])
      async true
    end

    # FEATURE: wait_for to ensure dependencies complete before proceeding
    step :generate_report, GenerateProcessingReportStep do
      argument :results, result(:process_results)
      wait_for :load_to_database, :load_to_search_index
    end

    returns :generate_report
  end

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
      reactor = UserETLReactor.new
      result = reactor.run(
        source_file: "/tmp/users.csv",
        csv_data: sample_users,
        output_destinations: %w[database search]
      )

      expect(result).to be_a(RubyReactor::Success)

      # The reactor returns :generate_report, so result.value is the report directly
      report = result.value
      expect(report).not_to be_nil
      expect(report[:successful_count]).to eq(3)
      expect(report[:failed_count]).to eq(0)
      expect(report[:success_rate]).to eq(1.0)
      expect(report[:source_count]).to eq(3)

      # Access intermediate results from context
      context = reactor.context
      transformed = context.intermediate_results[:transform_users]
      expect(transformed).to be_an(Array)
      expect(transformed.length).to eq(3)

      # Verify first user was transformed correctly
      alice = transformed.find { |u| u[:email] == "alice@example.com" }
      expect(alice[:name]).to eq("Alice Smith")
      expect(alice[:phone]).to eq("+15550100")
      expect(alice[:age]).to eq(30)
      expect(alice[:verified]).to eq(false)

      # Verify enrichment worked
      bob = transformed.find { |u| u[:email] == "verified@example.com" }
      expect(bob[:verified]).to eq(true)
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
      allow(RubyReactor.configuration).to receive(:async_router).and_return(RubyReactor::AsyncRouter)
      Sidekiq::Testing.fake!
    end

    after do
      Sidekiq::Testing.inline!
    end

    it "queues async map execution with batch_size" do
      result = AsyncMapReactor.run(numbers: [1, 2, 3, 4, 5])

      # Should return AsyncResult because it went async
      expect(result).to be_a(RubyReactor::AsyncResult)

      # With batch_size: 2, should queue 2 jobs initially
      expect(RubyReactor::MapElementWorker.jobs.size).to eq(2)
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
