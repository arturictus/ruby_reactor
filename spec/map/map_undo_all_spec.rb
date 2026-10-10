# frozen_string_literal: true

require "spec_helper"

# 010 US7 (FR-027–FR-034, R-13, P-6): a map declaring `undo_all` is rolled
# back with ONE call to that block, given the completed elements' results,
# instead of each element's own undos.
module MapUndoAllSpec
  def self.calls
    @calls ||= []
  end

  # `undo_all` records what it got; `outcome` decides what it returns.
  def self.outcome=(value)
    @outcome = value
  end

  def self.bulk
    lambda do |results|
      list = results.map { |result| result[:e2] }.to_a # each element's results hash (no `returns`)
      MapUndoAllSpec.calls << list
      RollbackRecorder.record("undo_all:#{list.size}")
      case @outcome
      when :raise then raise "bulk refund down"
      when :failure then RubyReactor.Failure("bulk refund refused")
      else :refunded
      end
    end
  end

  MapRollbackFixtures.parent(self, :FanOut, MapRollbackFixtures::ElemOk, fan_out: true, batch_size: 5,
                                                                         b_fails: true, undo_all: bulk)
  MapRollbackFixtures.parent(self, :FanOutOk, MapRollbackFixtures::ElemOk, fan_out: true, batch_size: 5,
                                                                           undo_all: bulk)
  MapRollbackFixtures.parent(self, :Inline, MapRollbackFixtures::ElemOk, b_fails: true, undo_all: bulk)
  MapRollbackFixtures.parent(self, :AtomicFanOut, MapRollbackFixtures::Elem, fan_out: true, batch_size: 5,
                                                                             undo_all: bulk)
  MapRollbackFixtures.parent(self, :FirstFails, MapRollbackFixtures::Elem, fan_out: true, batch_size: 1,
                                                                           undo_all: bulk)

  # Element 1's e2 is cut off by an interruption: the run is `aborted`.
  class ElemCrash < RollbackRecorder::Reactor
    tag "e"
    input :i
    input :fail_at, optional: true
    recording_step :e1, idx: true
    recording_step(:e2, after: :e1, idx: true) do
      run do |inputs, _ctx|
        raise Interrupt if inputs.i == 1

        RubyReactor.Success("e.e2[#{inputs.i}]-value")
      end
    end
  end
  MapRollbackFixtures.parent(self, :InlineCrash, ElemCrash, undo_all: bulk)
end

RSpec.describe "map undo_all (010 US7)" do
  let(:storage) { RubyReactor.configuration.storage_adapter }
  let(:logger) { RubyReactor.configuration.logger }
  let(:values) { ->(range) { range.map { |i| "e.e2[#{i}]-value" } } }

  before do
    RollbackRecorder.reset!
    MapUndoAllSpec.calls.clear
    MapUndoAllSpec.outcome = :ok
    allow(logger).to receive(:info).and_call_original
  end

  def drain
    QueueProbe.drain_tracking("MapElementRollbackWorker")
  end

  def undo_entries
    RollbackRecorder.log.grep(/\Aundo:e\./)
  end

  def trace_entry(klass, id)
    klass.find(id).context.execution_trace.find { |e| (e[:type] || e["type"]).to_s == "undo_all" }
  end

  for_each_async_backend do
    it "calls undo_all once with every completed result, in index order, and no element undo" do
      id = MapUndoAllSpec::FanOut.run(items: (0...20).to_a).execution_id

      probe = drain

      expect(probe[:max_burst]).to eq(0) # no element rollback jobs
      expect(MapUndoAllSpec.calls).to eq([values.call(0...20)])
      expect(undo_entries).to be_empty
      expect(RollbackRecorder.log.index("undo:a")).to be > RollbackRecorder.log.index("undo_all:20")
      expect(MapUndoAllSpec::FanOut.find(id).context.status.to_s).to eq("failed")
      expect(trace_entry(MapUndoAllSpec::FanOut, id)).to include(count: 20).or include("count" => 20)
      expect(logger).to have_received(:info).with(/ruby_reactor.map.rollback.undo_all.started.*count=20/)
      expect(logger).to have_received(:info).with(/ruby_reactor.map.rollback.undo_all.completed.*count=20.*failed=0/)
    end

    it "passes only the completed results of an atomic map whose element failed" do
      MapUndoAllSpec::AtomicFanOut.run(items: (0...20).to_a, fail_at: 7)

      drain

      expect(MapUndoAllSpec.calls.size).to eq(1)
      passed = MapUndoAllSpec.calls.first
      expect(passed).not_to include("e.e2[7]-value")
      expect(passed).to eq(passed.sort_by { |v| v[/\d+/].to_i })
      expect(RollbackRecorder.log).to include("compensate:e.e2[7]")
      expect(undo_entries - ["undo:e.e1[7]"]).to be_empty # only the failed element's own rollback
    end

    it "does not call undo_all when no element completed" do
      MapUndoAllSpec::FirstFails.run(items: (0...4).to_a, fail_at: 0)

      drain

      expect(MapUndoAllSpec.calls).to be_empty
      expect(RollbackRecorder.log).to include("undo:a")
    end

    it "is called once by a manual undo of a completed run" do
      id = MapUndoAllSpec::FanOutOk.run(items: (0...6).to_a).execution_id
      drain
      expect(MapUndoAllSpec::FanOutOk.find(id).context.status.to_s).to eq("completed")

      MapUndoAllSpec::FanOutOk.undo(id)

      expect(MapUndoAllSpec.calls).to eq([values.call(0...6)])
      expect(RollbackRecorder.log.last).to eq("undo:a")
    end

    it "reports a result slot that expired, and passes the rest", redis_only: "simulates Redis TTL expiry; ActiveRecord keeps history" do
      id = MapUndoAllSpec::FanOutOk.run(items: (0...6).to_a).execution_id
      drain
      redis.hdel("reactor:MapUndoAllSpec::FanOutOk:map:#{id}:m:results", "3")

      MapUndoAllSpec::FanOutOk.undo(id)

      expect(MapUndoAllSpec.calls).to eq([values.call([0, 1, 2, 4, 5])])
      expect(logger).to have_received(:info).with(/ruby_reactor.map.rollback.completed.*failed=1/)
    end
  end

  it "calls undo_all the same way for an inline map" do
    id = MapUndoAllSpec::Inline.new.tap { |r| r.run(items: (0...5).to_a) }.context.context_id

    expect(MapUndoAllSpec.calls).to eq([values.call(0...5)])
    expect(undo_entries).to be_empty
    expect(RollbackRecorder.log.last).to eq("undo:a")
    expect(trace_entry(MapUndoAllSpec::Inline, id)).to include(count: 5).or include("count" => 5)
  end

  {
    raise: [:raised, "bulk refund down"],
    failure: [:returned_failure, "bulk refund refused"]
  }.each do |outcome, (reason, message)|
    it "reports an undo_all that ends in #{reason}, and still undoes the steps before the map" do
      MapUndoAllSpec.outcome = outcome

      result = MapUndoAllSpec::Inline.run(items: (0...3).to_a)

      expect(result).to be_failure
      expect(result.rollback_failures).to include(a_hash_including(step: :m, kind: :undo_all, reason: reason,
                                                                   message: message))
      expect(RollbackRecorder.log.last).to eq("undo:a")
    end
  end

  it "replays an aborted inline element itself, and passes only completed results" do
    reactor = MapUndoAllSpec::InlineCrash.new
    expect { reactor.run(items: [0, 1, 2]) }.to raise_error(Interrupt)
    id = reactor.context.context_id
    RollbackRecorder.log.clear

    MapUndoAllSpec::InlineCrash.undo(id)

    expect(RollbackRecorder.log).to eq(["undo:e.e1[1]", "undo_all:1", "undo:a"])
    expect(MapUndoAllSpec.calls).to eq([["e.e2[0]-value"]])
  end

  context "with 10,000 completed elements", :slow do
    it "makes one call, no element undo, and reads results without holding them all" do
      samples = []
      klass = Class.new(RollbackRecorder::Reactor) do
        def self.name = "MapUndoAllSpec::Large"
        input :items
        recording_step :a
        map :m, MapRollbackFixtures::ElemOk do
          source input(:items)
          argument :i, element(:m)
          fan_out(batch_size: 50)
          undo_all do |results|
            count = 0
            results.each do
              count += 1
              next unless (count % 1000).zero?

              GC.start # live objects only, not garbage awaiting collection
              samples << GC.stat(:heap_live_slots)
            end
            RollbackRecorder.record("undo_all:#{count}")
          end
        end
        recording_step :b, after: :m, fail: true
      end
      stub_const("MapUndoAllSpec::Large", klass)

      klass.run(items: (0...10_000).to_a)
      RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs(max_iterations: 5_000)

      expect(RollbackRecorder.log).to include("undo_all:10000")
      expect(undo_entries).to be_empty
      # Flat within 10% from the first sample to the last: the enumerator
      # holds one 1,000-slot chunk at a time, never all 10,000 results.
      expect(samples.last).to be < samples.first * 1.1
    end
  end
end
