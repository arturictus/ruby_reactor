# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Async Map Execution without batch_size" do
  before do
    # Ensure clean state
    Sidekiq::Worker.clear_all
  end

  it "runs elements through the per-element worker path (no single-worker strategy)" do
    # Run initial execution
    reactor = MapTestReactors::SingleWorkerMapReactor.new
    reactor.run(numbers: [1, 2, 3])
    context_id = reactor.context.context_id

    # An async map without batch_size now fans out per-element workers
    # (batch_size defaults to the full source size) instead of a single
    # MapExecutionWorker. One worker per element.
    expect(RubyReactor::SidekiqWorkers::MapElementWorker.jobs.size).to eq(3)

    # Process the elements and the collector that aggregates them.
    RubyReactor::SidekiqWorkers::MapElementWorker.drain
    RubyReactor::SidekiqWorkers::MapCollectorWorker.drain

    # Verify result in Redis
    storage = RubyReactor.configuration.storage_adapter
    context = storage.retrieve_context(context_id, MapTestReactors::SingleWorkerMapReactor.name)

    expect(context).not_to be_nil

    # DoubleReactor returns :double, so the lazily-collected results are [2, 4, 6].
    result_data = context["intermediate_results"]["doubled_numbers"]
    expect(result_data["_type"]).to eq("Map::ResultEnumerator")

    enumerator = RubyReactor::ContextSerializer.deserialize_value(result_data)
    expect(enumerator.to_a.map(&:value)).to eq([2, 4, 6])
  end
end
