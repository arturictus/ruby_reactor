# frozen_string_literal: true

require "spec_helper"

class BatchSizeReactor < RubyReactor::Reactor
  input :numbers

  step :double do
    argument :number, input(:numbers)
    run { |args, _| RubyReactor::Success(args[:number] * 2) }
  end
end

class BatchMapReactor < RubyReactor::Reactor
  input :numbers

  map :doubled_numbers, BatchSizeReactor do
    source input(:numbers)
    argument :number, element(:doubled_numbers)
    async true, batch_size: 2
  end
end

RSpec.describe "Map Batch Size Execution" do
  before do
    # Use real Redis from spec_helper configuration
    # But we need to ensure AsyncRouter is used instead of WorkerMock for this test
    allow(RubyReactor.configuration).to receive(:async_router).and_return(RubyReactor::AsyncRouter)

    Sidekiq::Testing.fake!
  end

  after do
    Sidekiq::Testing.inline!
  end

  it "queues only batch_size elements initially and queues more as they finish" do
    # 10 elements
    numbers = (1..10).to_a
    result = BatchMapReactor.run(numbers: numbers)

    expect(result).to be_a(RubyReactor::RetryQueuedResult)

    # Should only queue 2 jobs initially because batch_size is 2
    expect(RubyReactor::MapElementWorker.jobs.size).to eq(2)

    # Process the first 2 jobs manually to verify they queue the next batch
    initial_jobs = RubyReactor::MapElementWorker.jobs.dup
    RubyReactor::MapElementWorker.clear

    initial_jobs.each do |job|
      RubyReactor::MapElementWorker.new.perform(*job["args"])
    end

    # Each finished job should have queued 1 more job (total 2 more)
    # So queue should have 2 jobs again (index 2 and 3)
    expect(RubyReactor::MapElementWorker.jobs.size).to eq(2)

    # Check that we are processing the right indices
    job_args = RubyReactor::MapElementWorker.jobs.map { |j| j["args"].first }
    indices = job_args.map { |a| a["index"] }
    expect(indices).to contain_exactly(2, 3)
  end
end
