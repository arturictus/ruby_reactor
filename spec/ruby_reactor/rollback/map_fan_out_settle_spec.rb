# frozen_string_literal: true

require "spec_helper"

# US1-3 (F-01, F-05): a fan-out map rolls back every element that succeeded,
# whatever order the element jobs ran in. A fail-fast failure is applied only
# once every index has settled.
module MapFanOutSettleSpec
  class Elem < RollbackRecorder::Reactor
    tag "e"
    input :i
    recording_step :e1, idx: true
    recording_step :e2, after: :e1, idx: true, fail: ->(inputs) { inputs.i == 2 }
  end

  class ElemOk < RollbackRecorder::Reactor
    tag "e"
    input :i
    recording_step :e1, idx: true
    recording_step :e2, after: :e1, idx: true
  end

  class ElemFailsAtOne < RollbackRecorder::Reactor
    tag "e"
    input :i
    recording_step :e1, idx: true, fail: ->(inputs) { inputs.i == 1 }
  end

  class FailsInMap < RollbackRecorder::Reactor
    input :items
    recording_step :a
    map :m, Elem do
      source input(:items)
      argument :i, element(:m)
      fan_out
    end
    recording_step :b, after: :m
  end

  class LaterFailure < RollbackRecorder::Reactor
    input :items
    recording_step :a
    map :m, ElemOk do
      source input(:items)
      argument :i, element(:m)
      fan_out
    end
    recording_step :b, after: :m, fail: true
  end

  # Element 2 fails and its own e1 undo fails; element 0's e1 undo fails when
  # the map rolls back.
  class ElemUndoFails < RollbackRecorder::Reactor
    tag "e"
    input :i
    recording_step :e1, idx: true, undo_fails: ->(inputs) { [0, 2].include?(inputs.i) }
    recording_step :e2, after: :e1, idx: true, fail: ->(inputs) { inputs.i == 2 }
  end

  class InlineUndoFails < RollbackRecorder::Reactor
    input :items
    recording_step :a
    map :m, ElemUndoFails do
      source input(:items)
      argument :i, element(:m)
    end
  end

  class FanOutUndoFails < RollbackRecorder::Reactor
    input :items
    recording_step :a
    map :m, ElemUndoFails do
      source input(:items)
      argument :i, element(:m)
      fan_out
    end
  end

  class Batched < RollbackRecorder::Reactor
    input :items
    map :m, ElemFailsAtOne do
      source input(:items)
      argument :i, element(:m)
      fan_out batch_size: 2
    end
  end
end

RSpec.describe "map rollback (fan-out)" do
  let(:storage) { RubyReactor.configuration.storage_adapter }
  let(:items) { { items: [0, 1, 2, 3] } }

  def drain
    RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs
  end

  def element_job?(job)
    klass = job.respond_to?(:worker_class) ? job.worker_class : job.job_class
    klass.name.end_with?("MapElementWorker")
  end

  # Re-queues the pending element jobs in the order the block returns them.
  def reorder_element_jobs
    if async_backend == :sidekiq
      jobs = RubyReactor::Adapters::Sidekiq::MapElementWorker.jobs
      jobs.replace(yield(jobs.dup))
    else
      queue = ActiveJob::Base.queue_adapter.enqueued_jobs
      elements = queue.select { |j| j[:job].name.end_with?("MapElementWorker") }
      queue.replace((queue - elements) + yield(elements))
    end
  end

  def perform_element_jobs
    RubyReactor::RSpec::AsyncTestHelpers.pending_async_jobs.select { |j| element_job?(j) }.each(&:perform!)
  end

  def elements(*indexes, fail_at: nil)
    indexes.flat_map do |i|
      base = ["run:e.e1[#{i}]", "run:e.e2[#{i}]"]
      i == fail_at ? base + ["compensate:e.e2[#{i}]", "undo:e.e1[#{i}]"] : base
    end
  end

  def undone(*indexes)
    indexes.flat_map { |i| ["undo:e.e2[#{i}]", "undo:e.e1[#{i}]"] }
  end

  for_each_async_backend do
    it "rolls back the elements before the failing one (S-map-04)" do
      id = MapFanOutSettleSpec::FailsInMap.run(items).execution_id
      drain

      expect(RollbackRecorder.log).to eq(["run:a", *elements(0, 1, 2, fail_at: 2), *undone(1, 0), "undo:a"])
      expect(MapFanOutSettleSpec::FailsInMap.find(id).result.step_name.to_s).to eq("m")
    end

    it "rolls back an element that ran before the failure in job order 3, 2, 1, 0 (S-map-04b)" do
      MapFanOutSettleSpec::FailsInMap.run(items)
      reorder_element_jobs(&:reverse)
      drain

      expect(RollbackRecorder.log).to eq(["run:a", *elements(3), *elements(2, fail_at: 2), *undone(3), "undo:a"])
    end

    it "undoes every element, then the steps before the map, when a later step fails (S-map-06)" do
      MapFanOutSettleSpec::LaterFailure.run(items)
      drain

      expect(RollbackRecorder.log).to eq(
        ["run:a", *elements(0, 1, 2, 3), "run:b", "compensate:b", *undone(3, 2, 1, 0), "undo:a"]
      )
    end

    it "leaves no succeeded element without rollback across 100 shuffled job orders (SC-003)" do
      random = Random.new(8)
      100.times do
        RollbackRecorder.reset!
        id = MapFanOutSettleSpec::FailsInMap.run(items).execution_id
        reorder_element_jobs { |jobs| jobs.shuffle(random: random) }
        drain

        ran = RollbackRecorder.log.grep(/\Arun:e\.e2\[(\d)\]/) { Regexp.last_match(1).to_i } - [2]
        ran.each { |i| expect(RollbackRecorder.log).to include("undo:e.e2[#{i}]", "undo:e.e1[#{i}]") }
        storage.retrieve_map_element_context_ids("#{id}:m", "MapFanOutSettleSpec::FailsInMap").uniq.each do |cid|
          data = storage.retrieve_context(cid, "MapFanOutSettleSpec::Elem")
          expect(data["undo_stack"]).to be_empty if data["status"] == "completed"
        end
        expect(MapFanOutSettleSpec::FailsInMap.find(id).result.rollback_failures).to be_empty
      end
    end

    it "settles undispatched indices as skipped and resolves the failure once" do
      id = MapFanOutSettleSpec::Batched.run(items: (0..5).to_a).execution_id
      drain

      map_id = "#{id}:m"
      results = storage.retrieve_map_results(map_id, "MapFanOutSettleSpec::Batched")
      expect(results[2..]).to eq([{ "_skipped" => true }] * 4)
      # DECRBY 0 reads the counter on either adapter without changing it.
      expect(storage.decrement_map_counter_by(map_id, 0, "MapFanOutSettleSpec::Batched")).to eq(0)
      trace = MapFanOutSettleSpec::Batched.find(id).context.execution_trace
      expect(trace.count { |e| e[:type].to_s == "compensate" && e[:step].to_s == "m" }).to eq(1)
      expect(RubyReactor::Map::Sweeper.run_once[:redispatched]).to eq(0)
    end

    # A collector that found the map unsettled still holds the lock when the
    # last element's collector arrives: that one must wait, not drop.
    it "applies a fail-fast failure when its collector meets another collector's lock" do
      id = MapFanOutSettleSpec::FailsInMap.run(items).execution_id
      perform_element_jobs
      holder = RubyReactor::Lock.new("map_collect:#{id}:m", owner: "deferring-collector", ttl: 30, auto_extend: false)
      holder.acquire
      releaser = Thread.new do
        sleep 0.3
        holder.release
      end
      drain
      releaser.join

      expect(RollbackRecorder.log).to eq(["run:a", *elements(0, 1, 2, fail_at: 2), *undone(1, 0), "undo:a"])
      expect(MapFanOutSettleSpec::FailsInMap.find(id).context.status.to_s).to eq("failed")
    end

    it "fails with the inline map's shape when an element's rollback fails" do
      inline = MapFanOutSettleSpec::InlineUndoFails.run(items)
      id = MapFanOutSettleSpec::FanOutUndoFails.run(items).execution_id
      drain
      fan_out = MapFanOutSettleSpec::FanOutUndoFails.find(id).result

      shape = ->(failure) { [failure.exception_class, failure.step_name.to_s, failure.error.to_s] }
      expect(shape.call(fan_out)).to eq(shape.call(inline))
      expect(fan_out.rollback_failures).to eq(inline.rollback_failures)
      expect(inline.rollback_failures.map do |entry|
        entry[:message]
      end).to eq(["undo e.e1[2] failed", "undo e.e1[0] failed"])
    end

    it "reports every element when the map's element index expired before a later failure", redis_only: "simulates Redis TTL expiry; ActiveRecord keeps history" do
      id = MapFanOutSettleSpec::LaterFailure.run(items).execution_id
      perform_element_jobs
      redis.del("reactor:MapFanOutSettleSpec::LaterFailure:map:#{id}:m:element_contexts")
      drain

      result = MapFanOutSettleSpec::LaterFailure.find(id).result
      expect(RollbackRecorder.log.grep(/\Aundo:e\./)).to be_empty
      unavailable = result.rollback_failures.select { |entry| entry[:reason] == :context_unavailable }
      expect(unavailable.map { |entry| entry[:element_index] }).to contain_exactly(0, 1, 2, 3)
    end

    it "reports an element whose liveness lock is held, and undoes the others" do
      id = MapFanOutSettleSpec::LaterFailure.run(items).execution_id
      perform_element_jobs
      holder = RubyReactor::Lock.new("map_element:#{id}:m:0", owner: "x", ttl: 30, wait: 0, auto_extend: false)
      holder.acquire
      drain

      result = MapFanOutSettleSpec::LaterFailure.find(id).result
      expect(result.rollback_failures).to include(
        a_hash_including(reason: :element_in_flight, element_index: 0, map_step: :m)
      )
      expect(RollbackRecorder.log).to include(*undone(3, 2, 1))
      expect(RollbackRecorder.log).not_to include("undo:e.e1[0]")
    ensure
      holder&.release
    end
  end
end
