# frozen_string_literal: true

require "spec_helper"

# 009 R-03, S-1: once every element has settled, the collector signals the
# map's OWNER run (the top-level context) and writes no context itself. The
# owner's Worker resumes, and `MapStep#run` adopts the settled outcome.
module MapOwnerResumeSpec
  MapRollbackFixtures.parent(self, :Completes, MapRollbackFixtures::ElemOk, fan_out: true)
  MapRollbackFixtures.parent(self, :FailsInMap, MapRollbackFixtures::Elem, fan_out: true)

  class ElemRaises < RollbackRecorder::Reactor
    tag "e"
    input :i
    input :fail_at, optional: true
    recording_step :e1, idx: true, fail: :raise
  end
  MapRollbackFixtures.parent(self, :RaisesInMap, ElemRaises, fan_out: true)
  MapRollbackFixtures.parent(self, :RaisesInMapInline, ElemRaises)
end

RSpec.describe "fan-out map completion resumes the owner" do
  let(:storage) { RubyReactor.configuration.storage_adapter }
  let(:items) { { items: [0, 1, 2, 3] } }

  def perform_jobs(suffix)
    while (job = QueueProbe.pending.find { |j| QueueProbe.class_of(j).name.end_with?(suffix) })
      job.perform!
    end
  end

  def owner_jobs
    QueueProbe.pending.select { |j| QueueProbe.class_of(j).name.end_with?("::Worker") }
  end

  def worker_class
    async_backend == :sidekiq ? RubyReactor::Adapters::Sidekiq::Worker : RubyReactor::Adapters::ActiveJob::Worker
  end

  def drain
    RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs
  end

  for_each_async_backend do
    it "enqueues the owner's Worker once, and the collector stores no context" do
      id = MapOwnerResumeSpec::Completes.run(items).execution_id
      perform_jobs("MapElementWorker")
      allow(storage).to receive(:store_context).and_call_original

      perform_jobs("MapCollectorWorker")

      expect(storage).not_to have_received(:store_context)
      expect(owner_jobs.map { |job| job.args.first }).to eq([id])
      drain
      expect(MapOwnerResumeSpec::Completes.find(id).context.status.to_s).to eq("completed")
      expect(RollbackRecorder.log).to include("run:b")
    end

    it "enqueues one owner Worker for two collector deliveries" do
      id = MapOwnerResumeSpec::Completes.run(items).execution_id
      perform_jobs("MapElementWorker")
      perform_jobs("MapCollectorWorker")
      RubyReactor::Map::Collector.perform(
        parent_context_id: id, map_id: "#{id}:m", parent_reactor_class_name: MapOwnerResumeSpec::Completes.name,
        step_name: "m", strict_ordering: true, timeout: 3600
      )

      expect(owner_jobs.size).to eq(1)
    end

    it "adopts an unsettled map on an early resume without dispatching again" do
      id = MapOwnerResumeSpec::Completes.run(items).execution_id
      element_jobs = QueueProbe.enqueued("MapElementWorker")
      collector_jobs = QueueProbe.enqueued("MapCollectorWorker")
      before = storage.retrieve_context(id, MapOwnerResumeSpec::Completes.name)["map_operations"]

      executor = worker_class.new.perform(id, MapOwnerResumeSpec::Completes.name)

      expect(executor.result).to be_a(RubyReactor::DispatchResult)
      expect(QueueProbe.enqueued("MapElementWorker")).to eq(element_jobs)
      expect(QueueProbe.enqueued("MapCollectorWorker")).to eq(collector_jobs)
      expect(storage.retrieve_context(id, MapOwnerResumeSpec::Completes.name)["map_operations"]).to eq(before)
    end

    it "fails the run through the executor on an atomic element failure" do
      id = MapOwnerResumeSpec::FailsInMap.run(items: [0, 1, 2, 3], fail_at: 1).execution_id
      drain

      reactor = MapOwnerResumeSpec::FailsInMap.find(id)
      expect(reactor.context.status.to_s).to eq("failed")
      expect(reactor.result.error).to include("boom e.e2[1]")
      expect(reactor.result.step_name.to_s).to eq("m")
      expect(reactor.result.rollback_failures).to be_empty
      expect(RollbackRecorder.log).to end_with("undo:e.e2[0]", "undo:e.e1[0]", "undo:a")
    end

    it "keeps the raising element's exception class, as the inline map does" do
      inline = MapOwnerResumeSpec::RaisesInMapInline.run(items)
      id = MapOwnerResumeSpec::RaisesInMap.run(items).execution_id
      drain

      expect(MapOwnerResumeSpec::RaisesInMap.find(id).result.exception_class).to eq("RuntimeError")
      expect(inline.exception_class).to eq("RuntimeError")
    end

    it "falls back to the parent ids for map metadata written before the upgrade" do
      id = MapOwnerResumeSpec::Completes.run(items).execution_id
      key = "reactor:#{MapOwnerResumeSpec::Completes.name}:map:#{id}:m:metadata"
      metadata = JSON.parse(redis.get(key)).except("owner_context_id", "owner_reactor_class_name")
      redis.set(key, metadata.to_json)

      drain

      expect(MapOwnerResumeSpec::Completes.find(id).context.status.to_s).to eq("completed")
    end
  end
end
