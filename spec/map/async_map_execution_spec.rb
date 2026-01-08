# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Async Map Execution" do
  before do
    # Use real Redis from spec_helper configuration
    # But we need to ensure AsyncRouter is used instead of WorkerMock for this test
    allow(RubyReactor.configuration).to receive(:async_router).and_return(RubyReactor::AsyncRouter)

    Sidekiq::Testing.fake!
  end

  after do
    Sidekiq::Testing.inline!
  end

  it "queues map element workers" do
    result = MapTestReactors::AsyncMapReactor.run(numbers: [1, 2, 3])

    # Should return AsyncResult because it went async
    expect(result).to be_a(RubyReactor::AsyncResult)

    # Check Sidekiq jobs
    # With batch_size: 1, only 1 job should be queued initially
    expect(RubyReactor::SidekiqWorkers::MapElementWorker.jobs.size).to eq(1)
  end

  it "processes map elements and triggers collector" do
    # Run initial execution
    reactor = MapTestReactors::AsyncMapReactor.new
    result = reactor.run(numbers: [1, 2, 3])
    expect(result).to be_a(RubyReactor::AsyncResult)

    context_id = reactor.context.context_id

    # Process jobs
    RubyReactor::SidekiqWorkers::MapElementWorker.drain

    # Check if Collector was queued
    expect(RubyReactor::SidekiqWorkers::MapCollectorWorker.jobs.size).to eq(2)

    # Process Collector
    RubyReactor::SidekiqWorkers::MapCollectorWorker.drain

    # Verify result in Redis
    storage = RubyReactor.configuration.storage_adapter
    context = storage.retrieve_context(context_id, MapTestReactors::AsyncMapReactor.name)

    expect(context).not_to be_nil
    expect(context).not_to be_nil

    result_data = context["intermediate_results"]["doubled_numbers"]
    expect(result_data).to be_a(Hash)
    expect(result_data["_type"]).to eq("Map::ResultEnumerator")

    # Verify contents by deserializing
    enumerator = RubyReactor::ContextSerializer.deserialize_value(result_data)
    expect(enumerator.map(&:value)).to eq([2, 4, 6])

    # Verify that children have parent_context_id
    map_id = "#{context_id}:doubled_numbers"
    child_context_ids = storage.retrieve_map_element_context_ids(map_id, MapTestReactors::AsyncMapReactor.name)
    expect(child_context_ids).not_to be_empty

    child_context_ids.each do |child_id|
      child_context = storage.find_context_by_id(child_id)
      expect(child_context["parent_context_id"]).to eq(context_id)
    end
  end
end
