# frozen_string_literal: true

require "spec_helper"

# Define a simple reactor for mapping
class SingleWorkerDoubleReactor < RubyReactor::Reactor
  input :number

  step :double do
    argument :number, input(:number)
    run { |args, _| RubyReactor::Success(args[:number] * 2) }
  end

  returns :double
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
  before do
    # Ensure clean state
    Sidekiq::Worker.clear_all
  end

  it "queues MapExecutionWorker for single worker strategy" do
    SingleWorkerMapReactor.run(numbers: [1, 2, 3])

    # Should queue MapExecutionWorker, NOT MapElementWorker
    expect(RubyReactor::MapExecutionWorker.jobs.size).to eq(1)
    expect(RubyReactor::MapElementWorker.jobs.size).to eq(0)
  end

  it "executes map loop in worker" do
    # Run initial execution
    reactor = SingleWorkerMapReactor.new
    result = reactor.run(numbers: [1, 2, 3])
    context_id = reactor.context.context_id

    # Process job
    RubyReactor::MapExecutionWorker.drain

    # Verify result in Redis
    storage = RubyReactor.configuration.storage_adapter
    context = storage.retrieve_context(context_id, SingleWorkerMapReactor.name)

    expect(context).not_to be_nil
    # Since SingleWorkerDoubleReactor returns :double, the result should be [2, 4, 6]
    expect(context["intermediate_results"]["doubled_numbers"]).to eq([2, 4, 6])
  end
end
