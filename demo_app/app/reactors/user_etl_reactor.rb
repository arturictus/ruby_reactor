# frozen_string_literal: true

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

class UserEtlReactor < RubyReactor::Reactor
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
