# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Single Worker Async Map Execution" do
  before do
    # Ensure clean state
    Sidekiq::Worker.clear_all
  end

  it "queues MapExecutionWorker for single worker strategy" do
    # Run initial execution
    reactor = MapTestReactors::SingleWorkerMapReactor.new
    reactor.run(numbers: [1, 2, 3])
    context_id = reactor.context.context_id

    # Should queue MapExecutionWorker, NOT MapElementWorker
    expect(RubyReactor::SidekiqWorkers::MapExecutionWorker.jobs.size).to eq(1)
    expect(RubyReactor::SidekiqWorkers::MapElementWorker.jobs.size).to eq(0)

    # Verify the job arguments
    job = RubyReactor::SidekiqWorkers::MapExecutionWorker.jobs.first
    args = job["args"].first
    expect(args["serialized_inputs"]).to be_a(Hash)
    expect(args["reactor_class_info"]).to eq({ "type" => "class", "name" => "MapTestReactors::DoubleReactor" })

    # Process the job
    RubyReactor::SidekiqWorkers::MapExecutionWorker.drain

    # Verify result in Redis
    storage = RubyReactor.configuration.storage_adapter
    context = storage.retrieve_context(context_id, MapTestReactors::SingleWorkerMapReactor.name)

    expect(context).not_to be_nil
    # Since DoubleReactor returns :double, the result should be [2, 4, 6]
    expect(context["intermediate_results"]["doubled_numbers"]).to eq([2, 4, 6])
  end
end
