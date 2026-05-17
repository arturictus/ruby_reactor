require "rails_helper"

RSpec.describe UserEtlReactor, type: :reactor do
  let(:csv_data) do
    [
      { "id" => 1, "email" => "verified@example.com", "name" => "Alice", "phone" => "+1 (555) 111-2222", "age" => "30" },
      { "id" => 2, "email" => "unverified@example.com", "name" => "Bob",   "phone" => "555-333-4444",     "age" => "42" }
    ]
  end

  let(:inputs) do
    { source_file: "fake.csv", csv_data: csv_data, output_destinations: [:db, :search] }
  end

  subject(:reactor) { test_reactor(described_class, inputs) }

  it "extracts, validates, transforms, loads, and reports" do
    expect(reactor).to be_success
    report = reactor.result.value
    expect(report[:successful_count]).to eq(2)
    expect(report[:source_count]).to eq(2)
    expect(report[:success_rate]).to eq(1.0)
  end

  it "loads to both destinations in parallel and waits before reporting" do
    expect(reactor).to have_run_step(:load_to_database)
    expect(reactor).to have_run_step(:load_to_search_index)
    expect(reactor).to have_run_step(:generate_report).after(:load_to_database)
    expect(reactor).to have_run_step(:generate_report).after(:load_to_search_index)
  end

  context "with an empty csv batch" do
    let(:csv_data) { [] }

    it "still completes successfully with zero counts" do
      reactor.mock_step(:process_results) do |args, _ctx, _orig|
        users = args[:transformed_users]
        RubyReactor::Success(
          successful: users, failed: [],
          source_count: args[:source_stats][:total_count],
          success_rate: 0.0
        )
      end
      expect(reactor).to be_success
      expect(reactor.result.value[:successful_count]).to eq(0)
    end
  end
end
