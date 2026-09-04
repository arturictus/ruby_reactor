# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Map Batch Size Execution" do
  before do
    # Use real Redis from spec_helper configuration
    # But we need to ensure Adapters::Sidekiq::Router is used instead of WorkerMock for this test
    allow(RubyReactor.configuration).to receive(:async_router).and_return(RubyReactor::Adapters::Sidekiq::Router)

    Sidekiq::Testing.fake!
  end

  after do
    Sidekiq::Testing.inline!
  end

  it "queues only batch_size elements initially and queues more as they finish" do
    # 10 elements
    numbers = (1..10).to_a
    result = MapTestReactors::BatchMapReactor.run(numbers: numbers)

    expect(result).to be_a(RubyReactor::DispatchResult)

    # Should only queue 2 jobs initially because batch_size is 2
    expect(RubyReactor::Adapters::Sidekiq::MapElementWorker.jobs.size).to eq(2)

    # Process the first batch
    initial_jobs = RubyReactor::Adapters::Sidekiq::MapElementWorker.jobs.dup
    RubyReactor::Adapters::Sidekiq::MapElementWorker.clear

    initial_jobs.each do |job|
      RubyReactor::Adapters::Sidekiq::MapElementWorker.new.perform(*job["args"])
    end

    # Should have queued 2 more jobs (indices 2 and 3)
    expect(RubyReactor::Adapters::Sidekiq::MapElementWorker.jobs.size).to eq(2)

    # Verify the indices
    job_args = RubyReactor::Adapters::Sidekiq::MapElementWorker.jobs.map { |j| j["args"].first }
    indices = job_args.map { |a| a["index"] }
    expect(indices).to contain_exactly(2, 3)
  end
end
