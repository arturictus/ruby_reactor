# frozen_string_literal: true

require "spec_helper"

module MapRecoverySpec
  MapRollbackFixtures.parent(self, :Batched, MapRollbackFixtures::ElemOk, fan_out: true, batch_size: 3)
end

# 009 R-10: the metadata never stored `batch_size` / `fail_fast`, so a
# re-dispatched element lost both — it stopped triggering batches and was no
# longer atomic.

# Phase 5 end-to-end: the map sweeper re-dispatches lost element jobs by index
# (exercising Dispatcher.requeue_index's real source resolution) and the map
# completes off the index-keyed results hash.
RSpec.describe "Map recovery (M1)" do
  before do
    allow(RubyReactor.configuration).to receive(:async_router).and_return(RubyReactor::Adapters::Sidekiq::Router)
    Sidekiq::Testing.fake!
  end

  after { Sidekiq::Testing.inline! }

  let(:storage) { RubyReactor.configuration.storage_adapter }
  let(:element_worker) { RubyReactor::Adapters::Sidekiq::MapElementWorker }
  let(:collector_worker) { RubyReactor::Adapters::Sidekiq::MapCollectorWorker }

  it "re-dispatches every missing index when element jobs are lost, then completes" do
    reactor = MapTestReactors::AsyncMapReactor.new
    reactor.run(numbers: [1, 2, 3])
    context_id = reactor.context.context_id

    # Simulate a hard kill: the dispatched element jobs are lost before running,
    # so no results are stored and no element locks are held.
    element_worker.jobs.clear
    collector_worker.jobs.clear

    result = RubyReactor::Map::Sweeper.run_once
    expect(result[:redispatched]).to eq(3) # indices 0,1,2 all missing
    expect(element_worker.jobs.size).to eq(3)

    # Run the recovered elements, collect, and resume the owner (009 R-03).
    element_worker.drain
    collector_worker.drain
    RubyReactor::Adapters::Sidekiq::Worker.drain

    data = storage.retrieve_context(context_id, MapTestReactors::AsyncMapReactor.name)
    enumerator = RubyReactor::ContextSerializer.deserialize_value(data["intermediate_results"]["doubled_numbers"])
    expect(enumerator.map(&:value)).to eq([2, 4, 6])
  end

  it "drops a duplicate element delivery while the original holds the element lock (M3 guard)" do
    reactor = MapTestReactors::AsyncMapReactor.new
    reactor.run(numbers: [1, 2, 3])
    map_id = "#{reactor.context.context_id}:doubled_numbers"
    job_args = element_worker.jobs.first["args"].first # index 0's element job

    counter_before = storage.retrieve_map_metadata(map_id, MapTestReactors::AsyncMapReactor.name)["count"]
    # A live original holds the element lock; the duplicate must do no work.
    RubyReactor::Lock.new("map_element:#{map_id}:0", owner: "live", ttl: 60, auto_extend: false).acquire

    element_worker.new.perform(job_args)

    # No result stored for index 0, and the completion counter was not decremented.
    expect(storage.missing_map_indices(map_id, 3, MapTestReactors::AsyncMapReactor.name)).to include(0)
    expect(storage.retrieve_map_metadata(map_id, MapTestReactors::AsyncMapReactor.name)["count"]).to eq(counter_before)
  end

  it "skips a missing index whose element is still alive (lock held)" do
    reactor = MapTestReactors::AsyncMapReactor.new
    reactor.run(numbers: [1, 2, 3])
    map_id = "#{reactor.context.context_id}:doubled_numbers"

    element_worker.jobs.clear
    # Pretend index 0's element is still running.
    RubyReactor::Lock.new("map_element:#{map_id}:0", owner: "live", ttl: 60, auto_extend: false).acquire

    result = RubyReactor::Map::Sweeper.run_once
    expect(result[:redispatched]).to eq(2) # 1 and 2 re-dispatched; 0 left to the live worker
  end

  describe "keeping batch_size and atomic (009 R-10)" do
    it "re-dispatches a dropped element with the map's batch_size and atomic" do
      id = MapRecoverySpec::Batched.run(items: [0, 1, 2]).execution_id
      dropped = element_worker.jobs.find { |job| job["args"].first["index"] == 1 }
      element_worker.jobs.delete(dropped)
      element_worker.drain

      expect(RubyReactor::Map::Sweeper.run_once[:redispatched]).to eq(1)
      args = element_worker.jobs.last["args"].first
      expect(args).to include("index" => 1, "batch_size" => 3, "atomic" => true)

      RubyReactor::RSpec::SidekiqHelpers.drain_async_jobs
      expect(MapRecoverySpec::Batched.find(id).context.status.to_s).to eq("completed")
    end
  end
end
