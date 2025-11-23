# frozen_string_literal: true

require "spec_helper"
require "ruby_reactor"
require "sidekiq/testing"
require "redis"

# Define a simple reactor for mapping
class SingleWorkerDoubleReactor < RubyReactor::Reactor
  input :number

  step :double do
    argument :number, input(:number)
    run { |args, _| RubyReactor::Success(args[:number] * 2) }
  end
end

class SingleWorkerMapReactor < RubyReactor::Reactor
  input :numbers

  map :doubled_numbers, SingleWorkerDoubleReactor do
    source input(:numbers)
    argument :number, element(:doubled_numbers)
    async true # Default single worker strategy
  end
end

RSpec.describe "Single Worker Async Map Execution" do
  let(:redis_client) { instance_double(Redis) }

  before do
    # Mock Redis
    allow(Redis).to receive(:new).and_return(redis_client)
    allow(redis_client).to receive(:set)
    allow(redis_client).to receive(:get)
    allow(redis_client).to receive(:expire)
    allow(redis_client).to receive(:call).with("JSON.SET", any_args)
    allow(redis_client).to receive(:call).with("JSON.GET", any_args).and_return(nil)

    # Configure storage
    RubyReactor.configure do |config|
      config.storage.adapter = :redis
    end
    # Reset adapter
    RubyReactor.configuration.instance_variable_set(:@storage_adapter, nil)

    Sidekiq::Testing.fake!
  end

  it "queues MapExecutionWorker for single worker strategy" do
    allow(redis_client).to receive(:call).with("JSON.SET", any_args)

    result = SingleWorkerMapReactor.run(numbers: [1, 2, 3])

    expect(result).to be_a(RubyReactor::RetryQueuedResult)

    # Should queue MapExecutionWorker, NOT MapElementWorker
    expect(RubyReactor::MapExecutionWorker.jobs.size).to eq(1)
    expect(RubyReactor::MapElementWorker.jobs.size).to eq(0)
  end

  it "executes map loop in worker" do
    # Setup context storage mock
    context_data = nil
    allow(redis_client).to receive(:call).with("JSON.SET", any_args) do |_, _, _, data|
      context_data = data
    end

    allow(redis_client).to receive(:call).with("JSON.GET", any_args) do
      context_data
    end

    # Run initial execution
    SingleWorkerMapReactor.run(numbers: [1, 2, 3])

    # Process job
    # We need to mock Executor#resume_execution because it will try to run
    # and we don't want to spin up a full execution in this unit test
    allow_any_instance_of(RubyReactor::Executor).to receive(:resume_execution)

    expect do
      RubyReactor::MapExecutionWorker.drain
    end.not_to raise_error

    # Verify result was set in context (we can check if set_result was called on context)
    # But context is deserialized inside worker.
    # We can verify resume_execution was called.
  end
end
