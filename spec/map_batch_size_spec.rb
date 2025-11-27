# frozen_string_literal: true

require "spec_helper"
require "ruby_reactor"
require "sidekiq/testing"
require "redis"

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
  let(:redis_client) { instance_double(Redis) }

  before do
    # Mock Redis
    allow(Redis).to receive(:new).and_return(redis_client)
    allow(redis_client).to receive(:set)
    allow(redis_client).to receive(:get)
    allow(redis_client).to receive(:expire)
    allow(redis_client).to receive(:call).with("JSON.SET", any_args)
    allow(redis_client).to receive(:call).with("JSON.GET", any_args).and_return(nil)
    allow(redis_client).to receive(:hset)
    allow(redis_client).to receive(:hgetall)
    allow(redis_client).to receive(:incr)
    allow(redis_client).to receive(:decr)

    RubyReactor.configure do |config|
      config.storage.adapter = :redis
    end
    RubyReactor.configuration.instance_variable_set(:@storage_adapter, nil)

    Sidekiq::Testing.fake!
  end

  after do
    Sidekiq::Testing.inline!
  end

  it "queues only batch_size elements initially and queues more as they finish" do
    # Mock context storage and counters
    redis_store = {}

    allow(redis_client).to receive(:call).with("JSON.SET", any_args) do |_, key, _, val|
      redis_store[key] = val
    end

    allow(redis_client).to receive(:call).with("JSON.GET", any_args) do |_, key|
      redis_store[key]
    end

    allow(redis_client).to receive(:set) do |key, val|
      redis_store[key] = val.to_i
    end

    allow(redis_client).to receive(:get) do |key|
      redis_store[key]
    end

    allow(redis_client).to receive(:incr) do |key|
      redis_store[key] ||= 0
      redis_store[key] += 1
    end

    allow(redis_client).to receive(:decr) do |key|
      redis_store[key] ||= 0
      redis_store[key] -= 1
    end

    allow(redis_client).to receive(:expire)
    allow(RubyReactor.configuration).to receive(:async_router).and_return(RubyReactor::AsyncRouter)

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
