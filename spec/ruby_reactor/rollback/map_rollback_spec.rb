# frozen_string_literal: true

require "spec_helper"

# US1 (F-01): a map rolls back every element that succeeded — when the map
# fails (compensate), and when a later step fails or the run is undone (undo) —
# by replaying each element's own step `undo`s, highest index first.
module MapRollbackSpec
  FAILS_AT_TWO = ->(inputs) { inputs.i == 2 }
  ITEMS = { items: [0, 1, 2, 3] }.freeze

  class Elem < RollbackRecorder::Reactor
    tag "e"
    input :i
    recording_step :e1, idx: true
    recording_step :e2, after: :e1, idx: true, fail: FAILS_AT_TWO
  end

  class ElemOk < RollbackRecorder::Reactor
    tag "e"
    input :i
    recording_step :e1, idx: true
    recording_step :e2, after: :e1, idx: true
  end

  class ElemUndoFailsAtOne < RollbackRecorder::Reactor
    tag "e"
    input :i
    recording_step :e1, idx: true, undo_fails: ->(inputs) { inputs.i == 1 }
  end

  def self.parent(name, element_class, tolerant: false, b_fails: false, collect: nil)
    klass = Class.new(RollbackRecorder::Reactor) do
      input :items
      recording_step :a
      map :m, element_class do
        source input(:items)
        argument :i, element(:m)
        atomic(!tolerant)
        collect(&collect) if collect
      end
      recording_step :b, after: :m, fail: b_fails
    end
    const_set(name, klass)
  end

  parent :FailsInMap, Elem
  parent :LaterFailure, ElemOk, b_fails: true
  parent :TolerantThenFails, Elem, tolerant: true, b_fails: true
  parent :CollectRaises, ElemOk, collect: ->(_results) { raise "collect exploded" }
  parent :Completes, ElemOk
  parent :UndoFailsAtOne, ElemUndoFailsAtOne, b_fails: true

  # b deletes element 1's context row (as if it expired past `context_ttl`), then fails.
  class ExpiresElementThenFails < RollbackRecorder::Reactor
    input :items
    recording_step :a
    map :m, ElemOk do
      source input(:items)
      argument :i, element(:m)
    end
    recording_step(:b, after: :m) do
      run do |_inputs, ctx|
        RollbackRecorder.record("run:b")
        storage = RubyReactor.configuration.storage_adapter
        id = storage.retrieve_map_element_context_ids("#{ctx.context_id}:m", ctx.reactor_class.name)[1]
        storage.delete_context(id, ElemOk.name)
        RubyReactor.Failure("boom b")
      end
    end
  end

  # b drops the map's element index (as if it expired past `context_ttl` while
  # the parent lived on), then fails.
  class IndexExpiresThenFails < RollbackRecorder::Reactor
    input :items
    recording_step :a
    map :m, ElemOk do
      source input(:items)
      argument :i, element(:m)
    end
    recording_step(:b, after: :m) do
      run do |_inputs, ctx|
        RollbackRecorder.record("run:b")
        Redis.new(url: REDIS_TEST_URL)
             .del("reactor:#{ctx.reactor_class.name}:map:#{ctx.context_id}:m:element_contexts")
        RubyReactor.Failure("boom b")
      end
    end
  end

  class ChildWithMap < RollbackRecorder::Reactor
    tag "child"
    input :items
    recording_step :c0
    map :m, Elem do
      source input(:items)
      argument :i, element(:m)
    end
  end

  class MapInCompose < RollbackRecorder::Reactor
    input :items
    recording_step :a
    compose(:child, ChildWithMap) { argument :items, input(:items) }
  end

  class Kid < RollbackRecorder::Reactor
    tag "k"
    recording_step :k1
  end

  class ElemComposes < RollbackRecorder::Reactor
    tag "e"
    input :i
    recording_step :e1, idx: true
    compose :kid, Kid
    recording_step :e2, after: %i[e1 kid], idx: true, fail: FAILS_AT_TWO
  end

  class ComposeInElement < RollbackRecorder::Reactor
    input :items
    map :m, ElemComposes do
      source input(:items)
      argument :i, element(:m)
    end
  end
end

# 009 T023: the 008 guarantees, on both paths. Twins of the reactors above,
# built inline and fan-out with `MapRollbackFixtures.parent`.
module MapRollbackBothPathsSpec
  F = MapRollbackFixtures

  # `a` → map `m` of F::ElemOk → `b`, whose run block is `b_run`.
  def self.custom_b(name, distributed, &b_run)
    klass = Class.new(RollbackRecorder::Reactor) do
      input :items
      recording_step :a
      map :m, F::ElemOk do
        source input(:items)
        argument :i, element(:m)
        fan_out if distributed
      end
      recording_step(:b, after: :m) { run(&b_run) }
    end
    const_set(name, klass)
  end

  [false, true].each do |distributed|
    suffix = distributed ? "FanOut" : "Inline"
    F.parent(self, :"FailsInMap#{suffix}", F::Elem, fan_out: distributed)
    F.parent(self, :"LaterFailure#{suffix}", F::ElemOk, fan_out: distributed, b_fails: true)
    F.parent(self, :"Tolerant#{suffix}", F::Elem, fan_out: distributed, atomic: false, b_fails: true)
    F.parent(self, :"CollectRaises#{suffix}", F::ElemOk, fan_out: distributed,
                                                         collect: ->(_results) { raise "collect exploded" })
    F.parent(self, :"Completes#{suffix}", F::ElemOk, fan_out: distributed)
    F.parent(self, :"UndoFails#{suffix}", F::ElemUndoFails, fan_out: distributed, b_fails: true)
    custom_b(:"ExpiresElement#{suffix}", distributed) do |_inputs, ctx|
      RollbackRecorder.record("run:b")
      storage = RubyReactor.configuration.storage_adapter
      id = storage.retrieve_map_element_context_ids("#{ctx.context_id}:m", ctx.reactor_class.name)[1]
      storage.delete_context(id, F::ElemOk.name)
      RubyReactor.Failure("boom b")
    end
    custom_b(:"IndexExpires#{suffix}", distributed) do |_inputs, ctx|
      RollbackRecorder.record("run:b")
      Redis.new(url: REDIS_TEST_URL).del("reactor:#{ctx.reactor_class.name}:map:#{ctx.context_id}:m:element_contexts")
      RubyReactor.Failure("boom b")
    end
  end

  # An element whose own steps include an inline map `n` (G3).
  class ElemWithNestedMap < RollbackRecorder::Reactor
    tag "e"
    input :i
    input :fail_at, optional: true
    recording_step :e1, idx: true
    map :n, F::ElemOk do
      source value([10, 11])
      argument :i, element(:n)
    end
    recording_step :e2, after: %i[e1 n], idx: true
  end
  F.parent(self, :NestedMapThenFails, ElemWithNestedMap, fan_out: true, b_fails: true)
  F.parent(self, :ManyInline, F::ElemOk, b_fails: true)
end

RSpec.describe "map rollback (inline)" do
  let(:storage) { RubyReactor.configuration.storage_adapter }

  def elements(*indexes, fail_at: nil)
    indexes.flat_map do |i|
      base = ["run:e.e1[#{i}]", "run:e.e2[#{i}]"]
      i == fail_at ? base + ["compensate:e.e2[#{i}]", "undo:e.e1[#{i}]"] : base
    end
  end

  def undone(*indexes)
    indexes.flat_map { |i| ["undo:e.e2[#{i}]", "undo:e.e1[#{i}]"] }
  end

  it "rolls back the elements that succeeded before the failing one (S-map-01)" do
    result = MapRollbackSpec::FailsInMap.run(MapRollbackSpec::ITEMS)

    expect(RollbackRecorder.log).to eq(["run:a", *elements(0, 1, 2, fail_at: 2), *undone(1, 0), "undo:a"])
    expect(result.step_name).to eq(:m)
  end

  it "undoes every element, highest index first, when a later step fails (S-map-03)" do
    result = MapRollbackSpec::LaterFailure.run(MapRollbackSpec::ITEMS)

    expect(RollbackRecorder.log).to eq(
      ["run:a", *elements(0, 1, 2, 3), "run:b", "compensate:b", *undone(3, 2, 1, 0), "undo:a"]
    )
    expect(result.step_name).to eq(:b)
  end

  it "never undoes a failed element twice with atomic false" do
    MapRollbackSpec::TolerantThenFails.run(MapRollbackSpec::ITEMS)

    expect(RollbackRecorder.log).to eq(
      ["run:a", *elements(0, 1, 2, 3, fail_at: 2), "run:b", "compensate:b", *undone(3, 1, 0), "undo:a"]
    )
  end

  it "rolls back every element when the collect block raises (FR-007)" do
    result = MapRollbackSpec::CollectRaises.run(MapRollbackSpec::ITEMS)

    expect(RollbackRecorder.log).to eq(["run:a", *elements(0, 1, 2, 3), *undone(3, 2, 1, 0), "undo:a"])
    expect(result.step_name).to eq(:m)
  end

  it "rolls back a map inside a compose, innermost first (S-map-07)" do
    MapRollbackSpec::MapInCompose.run(MapRollbackSpec::ITEMS)

    expect(RollbackRecorder.log).to eq(
      ["run:a", "run:child.c0", *elements(0, 1, 2, fail_at: 2), *undone(1, 0), "undo:child.c0", "undo:a"]
    )
  end

  it "unwinds a compose inside each element (S-map-08)" do
    MapRollbackSpec::ComposeInElement.run(MapRollbackSpec::ITEMS)

    expect(RollbackRecorder.log).to eq(
      %w[run:e.e1[0] run:k.k1 run:e.e2[0] run:e.e1[1] run:k.k1 run:e.e2[1] run:e.e1[2] run:k.k1 run:e.e2[2]
         compensate:e.e2[2] undo:k.k1 undo:e.e1[2]
         undo:e.e2[1] undo:k.k1 undo:e.e1[1] undo:e.e2[0] undo:k.k1 undo:e.e1[0]]
    )
  end

  it "undoes every element on a manual undo, once" do
    result = MapRollbackSpec::Completes.run(MapRollbackSpec::ITEMS)
    RollbackRecorder.reset!

    MapRollbackSpec::Completes.undo(result.execution_id)
    expect(RollbackRecorder.log).to eq(["undo:b", *undone(3, 2, 1, 0), "undo:a"])

    RollbackRecorder.reset!
    MapRollbackSpec::Completes.undo(result.execution_id)
    expect(RollbackRecorder.log).to be_empty
  end

  it "keeps rolling back the other elements when one element's undo fails (FR-005)" do
    result = MapRollbackSpec::UndoFailsAtOne.run(MapRollbackSpec::ITEMS)

    expect(RollbackRecorder.log).to eq(
      %w[run:a run:e.e1[0] run:e.e1[1] run:e.e1[2] run:e.e1[3] run:b compensate:b
         undo:e.e1[3] undo:e.e1[2] undo:e.e1[1] undo:e.e1[0] undo:a]
    )
    expect(result.rollback_failures).to include(
      a_hash_including(step: :e1, kind: :undo, map_step: :m, element_index: 1)
    )
  end

  it "reports an element whose context expired, and still undoes the others" do
    result = MapRollbackSpec::ExpiresElementThenFails.run(MapRollbackSpec::ITEMS)

    expect(RollbackRecorder.log).to end_with("compensate:b", *undone(3, 2, 0), "undo:a")
    expect(result.rollback_failures).to include(
      a_hash_including(step: :m, kind: :undo, reason: :context_unavailable, map_step: :m, element_index: 1)
    )
  end

  it "reports every element when the map's element index expired, never skipping them silently",
     redis_only: "simulates Redis TTL expiry; ActiveRecord keeps history" do
    result = MapRollbackSpec::IndexExpiresThenFails.run(MapRollbackSpec::ITEMS)

    expect(RollbackRecorder.log).to end_with("run:b", "compensate:b", "undo:a")
    expect(RollbackRecorder.log.grep(/\Aundo:e\./)).to be_empty
    unavailable = result.rollback_failures.select { |entry| entry[:reason] == :context_unavailable }
    expect(unavailable.map { |entry| entry[:element_index] }).to contain_exactly(0, 1, 2, 3)
  end

  it "rolls back nothing, without error, for an empty source" do
    result = MapRollbackSpec::LaterFailure.run(items: [])

    expect(RollbackRecorder.log).to eq(%w[run:a run:b compensate:b undo:a])
    expect(result.rollback_failures).to be_empty
  end

  # 009 R-14: a map's undo reads its declaration and the map records, never
  # the resolved source, so the parent does not store the source per map.
  it "records the completed map for undo with no arguments" do
    result = MapRollbackSpec::Completes.run(items: %w[marker-a marker-b])

    undo_stack = storage.retrieve_context(result.execution_id, MapRollbackSpec::Completes.name)["undo_stack"]
    expect(undo_stack.find { |entry| entry["step_name"] == "m" }["arguments"]).to eq({})
  end

  it "runs the element steps' existing undo blocks with no map-level declaration (US1-8)" do
    MapRollbackSpec::LaterFailure.run(MapRollbackSpec::ITEMS)

    expect(RollbackRecorder.log.grep(/\Aundo:e\./).size).to eq(8)
  end

  describe "on both paths (009)" do
    let(:storage) { RubyReactor.configuration.storage_adapter }
    let(:log) { RollbackRecorder.log }
    let(:items) { { items: [0, 1, 2, 3] } }

    def undone(*indexes)
      indexes.flat_map { |i| ["undo:e.e2[#{i}]", "undo:e.e1[#{i}]"] }
    end

    # The final result, whether the run finished here or in its Worker.
    def run(reactor, inputs = items)
      result = reactor.run(inputs)
      return result unless result.is_a?(RubyReactor::DispatchResult)

      RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs(max_iterations: 500)
      reactor.find(result.execution_id).result
    end

    [false, true].each do |fan_out|
      context "with fan_out: #{fan_out}" do
        let(:suffix) { fan_out ? "FanOut" : "Inline" }

        def fixture(name)
          MapRollbackBothPathsSpec.const_get(:"#{name}#{suffix}")
        end

        it "undoes every completed element, then the steps before the map, when the map fails" do
          result = run(fixture(:FailsInMap), items.merge(fail_at: 2))

          completed = log.grep(/\Arun:e\.e2\[(\d)\]/) { Regexp.last_match(1).to_i } - [2]
          completed.each { |i| expect(log.count("undo:e.e2[#{i}]")).to eq(1) }
          expect(log.count("undo:e.e1[2]")).to eq(1) # its own rollback, never the map's
          expect(log.last).to eq("undo:a")
          expect(result.step_name.to_s).to eq("m")
        end

        it "undoes every element, highest index first, when a later step fails" do
          result = run(fixture(:LaterFailure))

          expect(log).to end_with("compensate:b", *undone(3, 2, 1, 0), "undo:a")
          expect(result.step_name.to_s).to eq("b")
        end

        it "never undoes a failed element twice with atomic false" do
          run(fixture(:Tolerant), items.merge(fail_at: 2))

          expect(log).to end_with("compensate:b", *undone(3, 1, 0), "undo:a")
        end

        it "rolls back every element when the collect block raises" do
          result = run(fixture(:CollectRaises))

          expect(log).to end_with(*undone(3, 2, 1, 0), "undo:a")
          expect(result.step_name.to_s).to eq("m")
        end

        it "undoes every element on a manual undo, once" do
          reactor = fixture(:Completes)
          id = reactor.run(items).execution_id
          RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs
          RollbackRecorder.reset!

          reactor.undo(id)
          RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs
          expect(log).to eq(["undo:b", *undone(3, 2, 1, 0), "undo:a"])

          RollbackRecorder.reset!
          reactor.undo(id)
          expect(log).to be_empty
        end

        it "keeps rolling back the other elements when one element's undo fails" do
          result = run(fixture(:UndoFails))

          expect(log).to include("undo:e.e1[0]", "undo:e.e1[2]", "undo:e.e1[3]", "undo:a")
          expect(result.rollback_failures).to include(
            a_hash_including(step: :e1, kind: :undo, map_step: :m, element_index: 1)
          )
        end

        it "reports an element whose context expired, and still undoes the others" do
          result = run(fixture(:ExpiresElement))

          expect(log).to end_with("compensate:b", *undone(3, 2, 0), "undo:a")
          expect(result.rollback_failures).to contain_exactly(
            a_hash_including(step: :m, kind: :undo, reason: :context_unavailable, map_step: :m, element_index: 1)
          )
        end

        it "reports every element when the map's element index expired",
           redis_only: "simulates Redis TTL expiry; ActiveRecord keeps history" do
          result = run(fixture(:IndexExpires))

          expect(log.grep(/\Aundo:e\./)).to be_empty
          unavailable = result.rollback_failures.select { |entry| entry[:reason] == :context_unavailable }
          expect(unavailable.map { |entry| entry[:element_index] }).to contain_exactly(0, 1, 2, 3)
        end

        it "rolls back nothing, without error, for an empty source" do
          result = run(fixture(:LaterFailure), items: [])

          expect(log).to eq(%w[run:a run:b compensate:b undo:a])
          expect(result.rollback_failures).to be_empty
        end
      end
    end

    it "reads an inline map's element contexts 100 at a time, highest index first" do
      reads = []
      allow(storage).to receive(:retrieve_map_element_context_ids_from_tail).and_wrap_original do |orig, *args, **kw|
        reads << [args[2], args[3]]
        orig.call(*args, **kw)
      end

      MapRollbackBothPathsSpec::ManyInline.run(items: (0...250).to_a)

      expect(reads).to eq([[0, 100], [100, 100], [200, 100]])
      expect(log.grep(/\Aundo:e\.e2/).first(2)).to eq(["undo:e.e2[249]", "undo:e.e2[248]"])
    end

    it "rolls back a map nested in an element inline, inside the element's rollback job" do
      performed = 0
      id = MapRollbackBothPathsSpec::NestedMapThenFails.run(items).execution_id
      while (job = QueueProbe.next_job)
        performed += 1 if QueueProbe.class_of(job).name.end_with?("MapElementRollbackWorker")
        job.perform!
      end

      expect(performed).to eq(4)
      expect(MapRollbackBothPathsSpec::NestedMapThenFails.find(id).context.status.to_s).to eq("failed")
      element = log.drop_while { |event| event != "undo:e.e2[3]" }.take_while { |event| event != "undo:e.e1[3]" }
      expect(element).to eq(["undo:e.e2[3]", "undo:e.e2[11]", "undo:e.e1[11]", "undo:e.e2[10]", "undo:e.e1[10]"])
    end
  end
end
