# frozen_string_literal: true

require "spec_helper"
require "ruby_reactor"
require "sidekiq/testing"
require "redis"

# Define a simple reactor for mapping
class AsyncDoubleReactor < RubyReactor::Reactor
  input :number

  step :double do
    argument :number, input(:number)
    run { |args, _| RubyReactor::Success(args[:number] * 2) }
  end
end

class AsyncMapRootReactor < RubyReactor::Reactor
  input :numbers

  map :doubled_numbers, AsyncDoubleReactor do
    source input(:numbers)
    argument :number, element(:doubled_numbers)
    async true, batch_size: 1
  end
end

RSpec.describe "Async Map Execution" do
  let(:redis_client) { instance_double(Redis) }
  let(:adapter) { RubyReactor::Storage::RedisAdapter.new(url: "redis://localhost:6379") }

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

    # Use fake adapter for testing logic if needed, but here we want to test interaction with RedisAdapter
    # So we mock Redis calls.

    # Configure storage
    RubyReactor.configure do |config|
      config.storage.adapter = :redis
    end
    # Reset adapter to ensure fresh mock
    RubyReactor.configuration.instance_variable_set(:@storage_adapter, nil)

    Sidekiq::Testing.fake!
  end

  after do
    Sidekiq::Testing.inline!
  end

  it "queues map element workers" do
    # We need to mock context storage
    allow(redis_client).to receive(:call).with("JSON.SET", any_args)
    allow(redis_client).to receive(:set) # for map counter
    allow(redis_client).to receive(:expire)
    allow(RubyReactor.configuration).to receive(:async_router).and_return(RubyReactor::AsyncRouter)

    result = AsyncMapRootReactor.run(numbers: [1, 2, 3])

    # Should return RetryQueuedResult because it went async
    expect(result).to be_a(RubyReactor::RetryQueuedResult)

    # Check Sidekiq jobs
    expect(RubyReactor::MapElementWorker.jobs.size).to eq(3)
  end

  it "processes map elements and triggers collector" do
    # Setup context storage mock
    context_data = nil
    allow(redis_client).to receive(:call).with("JSON.SET", any_args) do |_, _, _, data|
      context_data = data
    end

    allow(redis_client).to receive(:call).with("JSON.GET", any_args) do
      context_data
    end

    # Setup map counter mock
    counter = 3
    allow(redis_client).to receive(:set)
    allow(redis_client).to receive(:decr) do
      counter -= 1
      counter
    end

    # Setup results storage
    results = {}
    allow(redis_client).to receive(:hset) do |_key, field, value|
      results[field] = value
    end

    allow(redis_client).to receive(:hgetall) do
      results
    end

    allow(redis_client).to receive(:expire)

    # Run initial execution
    result = AsyncMapRootReactor.run(numbers: [1, 2, 3])
    expect(result).to be_a(RubyReactor::RetryQueuedResult)

    # Process jobs
    RubyReactor::MapElementWorker.drain

    # Check if Collector was queued
    expect(RubyReactor::MapCollectorWorker.jobs.size).to eq(2)

    # Process Collector
    # We need to mock resume_execution logic or check if it calls Executor

    # Since we are mocking Redis, the Context deserialization in Collector will work
    # if we captured context_data correctly.

    # However, Collector creates a new Executor and calls resume_execution.
    # This might be hard to test fully with just Redis mocks because of complex object serialization.
    # But we can verify Collector runs.

    expect do
      RubyReactor::MapCollectorWorker.drain
    end.not_to raise_error
  end
end
