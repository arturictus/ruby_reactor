# frozen_string_literal: true

require "spec_helper"

# 009 US1-AS5, FR-006, FR-010, S-5, SC-003: a distributed map rollback
# survives a worker killed mid-undo, a lost job, a lost batch trigger, a lost
# owner resume, duplicate deliveries, a contended element lock and a
# superseded element context.
module MapRollbackRecoverySpec
  MapRollbackFixtures.parent(self, :Later, MapRollbackFixtures::ElemOk, fan_out: true, batch_size: 4, b_fails: true)
  MapRollbackFixtures.parent(self, :Batched, MapRollbackFixtures::ElemOk, fan_out: true, batch_size: 3, b_fails: true)
  MapRollbackFixtures.parent(self, :Interrupted, MapRollbackFixtures::ElemInterruptOnce, fan_out: true, batch_size: 4,
                                                                                         b_fails: true)
end

RSpec.describe "distributed map rollback recovery" do
  let(:storage) { RubyReactor.configuration.storage_adapter }
  let(:log) { RollbackRecorder.log }
  let(:reactor) { MapRollbackRecoverySpec::Later }
  let(:items) { { items: [0, 1, 2, 3] } }

  def drain
    RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs(max_iterations: 500)
  end

  def class_name(job)
    QueueProbe.class_of(job).name
  end

  def rollback_job?(job)
    class_name(job).end_with?("MapElementRollbackWorker")
  end

  def owner_job?(job)
    class_name(job).end_with?("::Worker")
  end

  def take(job)
    if async_backend == :sidekiq
      job.worker_class.jobs.delete(job.raw)
    else
      ActiveJob::Base.queue_adapter.enqueued_jobs.delete(job.raw)
    end
  end

  def requeue(job)
    if async_backend == :sidekiq
      job.worker_class.jobs << job.raw
    else
      ActiveJob::Base.queue_adapter.enqueued_jobs << job.raw
    end
  end

  def perform_until(&block)
    1000.times do
      return if QueueProbe.pending.any?(&block)

      (QueueProbe.next_job || raise("the awaited job was never queued")).perform!
    end
  end

  def rollback_jobs
    QueueProbe.pending.select { |job| rollback_job?(job) }
  end

  def args_of(job)
    job.args.first.to_h.transform_keys(&:to_s)
  end

  def element_index(job)
    data = storage.retrieve_context(args_of(job)["element_context_id"], MapRollbackFixtures::ElemOk.name)
    RubyReactor::ContextSerializer.deserialize_value(data["map_metadata"])[:index]
  end

  def status(id, klass = reactor)
    klass.find(id).context.status.to_s
  end

  for_each_async_backend do
    it "resumes an element interrupted mid-rollback after its last recorded undo" do
      id = MapRollbackRecoverySpec::Interrupted.run(items).execution_id
      while (job = QueueProbe.next_job)
        begin
          job.perform!
        rescue Interrupt
          requeue(job) # redelivered, as a killed worker's job is
        end
      end

      expect(log.count("undo:e.e2[0]")).to eq(1)
      expect(log.count("undo:e.e1[0]")).to eq(2)
      expect(status(id, MapRollbackRecoverySpec::Interrupted)).to eq("failed")
    end

    it "re-dispatches a lost rollback job from the map sweeper" do
      id = reactor.run(items).execution_id
      perform_until { |job| rollback_job?(job) }
      take(rollback_jobs.first)
      drain
      expect(status(id)).to eq("rolling_back")

      expect(RubyReactor::Map::Sweeper.run_once[:rollback_redispatched]).to eq(1)
      drain

      expect(status(id)).to eq("failed")
      (0..3).each { |i| expect(log.count("undo:e.e1[#{i}]")).to eq(1) }
    end

    it "claims the next batch from the map sweeper when the batch trigger was lost" do
      klass = MapRollbackRecoverySpec::Batched
      id = klass.run(items: (0..5).to_a).execution_id
      perform_until { |job| rollback_job?(job) }
      allow(RubyReactor::Map::Dispatcher).to receive(:dispatch_rollback_batch)
      rollback_jobs.each(&:perform!)
      allow(RubyReactor::Map::Dispatcher).to receive(:dispatch_rollback_batch).and_call_original
      drain
      expect(status(id, klass)).to eq("rolling_back")

      RubyReactor::Map::Sweeper.run_once
      drain

      expect(status(id, klass)).to eq("failed")
      (0..5).each { |i| expect(log.count("undo:e.e1[#{i}]")).to eq(1) }
    end

    it "re-enqueues a lost owner resume from the general sweeper" do
      id = reactor.run(items).execution_id
      map_id = "#{id}:m"
      while (job = QueueProbe.next_job)
        settled = storage.count_map_rollback_outcomes(map_id, reactor.name) == 4
        if owner_job?(job) && settled && status(id) == "rolling_back"
          take(job)
        else
          job.perform!
        end
      end
      expect(status(id)).to eq("rolling_back")

      expect(RubyReactor::Sweeper.run_once).to eq(1)
      drain

      expect(status(id)).to eq("failed")
      expect(log.count("undo:a")).to eq(1)
    end

    it "undoes an element once when its rollback job is delivered twice" do
      id = reactor.run(items).execution_id
      perform_until { |job| rollback_job?(job) }
      job = rollback_jobs.first
      index = element_index(job)
      job.perform!
      requeue(job)
      drain

      expect(log.count("undo:e.e2[#{index}]")).to eq(1)
      outcome = nil
      storage.each_map_rollback_outcome("#{id}:m", reactor.name) { |_, o| outcome = o if o["index"] == index }
      expect(outcome).to include("outcome" => "undone", "failures" => [])
      expect(status(id)).to eq("failed")
    end

    it "requeues itself on a contended element lock, and reports in flight only past the cap" do
      stub_const("RubyReactor::Step::MapStep::ELEMENT_LOCK_WAIT", 0)
      router = RubyReactor.configuration.async_router
      allow(router).to receive(:perform_map_element_rollback_in).and_call_original
      id = reactor.run(items).execution_id
      perform_until { |job| rollback_job?(job) }
      job = rollback_jobs.first
      index = element_index(job)
      holder = RubyReactor::Lock.new("map_element:#{id}:m:#{index}", owner: "live", ttl: 30, auto_extend: false)
      holder.acquire

      job.perform!

      expect(storage.count_map_rollback_outcomes("#{id}:m", reactor.name)).to eq(0)
      expect(router).to have_received(:perform_map_element_rollback_in)
        .with(anything, hash_including(attempt: 1, position: args_of(job)["position"]))
      holder.release
      drain
      expect(log.count("undo:e.e2[#{index}]")).to eq(1)
      expect(reactor.find(id).result.rollback_failures).to be_empty

      RollbackRecorder.reset!
      RubyReactor.configuration.lock_snooze_max_attempts = 2
      id = reactor.run(items).execution_id
      perform_until { |job| rollback_job?(job) }
      index = element_index(rollback_jobs.first)
      holder = RubyReactor::Lock.new("map_element:#{id}:m:#{index}", owner: "live", ttl: 30, auto_extend: false)
      holder.acquire
      drain

      expect(reactor.find(id).result.rollback_failures).to include(
        a_hash_including(reason: :element_in_flight, element_index: index, map_step: :m)
      )
    ensure
      holder&.release
    end

    it "undoes a superseded element context and its replacement once each" do
      id = reactor.run(items).execution_id
      perform_until { |job| owner_job?(job) && storage.count_map_results("#{id}:m", reactor.name) == 4 }
      element = MapRollbackFixtures::ElemOk.name
      original = storage.retrieve_map_element_context_ids("#{id}:m", reactor.name).find do |cid|
        RubyReactor::ContextSerializer.deserialize_value(storage.retrieve_context(cid,
                                                                                  element)["map_metadata"])[:index] == 2
      end
      copy = storage.retrieve_context(original, element).merge("context_id" => "superseded-2")
      storage.store_context("superseded-2", JSON.generate(copy), element)
      storage.store_map_element_context_id("#{id}:m", "superseded-2", reactor.name)

      drain

      expect(log.count("undo:e.e2[2]")).to eq(2)
      expect(reactor.find(id).result.rollback_failures).to be_empty
      [original, "superseded-2"].each { |cid| expect(storage.retrieve_context(cid, element)["undo_stack"]).to be_empty }
    end
  end
end
