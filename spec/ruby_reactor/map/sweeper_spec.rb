# frozen_string_literal: true

require "spec_helper"

# Phase 5d: the map sweeper recovers fan-out from a hard kill using the
# index-keyed results hash as the authoritative completion signal.
class MapSweepReactor < RubyReactor::Reactor
  input :items
  step :work do
    argument :items, input(:items)
    run { |a, _| RubyReactor.Success(a[:items]) }
  end
end

RSpec.describe RubyReactor::Map::Sweeper do
  subject(:sweeper) { described_class.new(storage: storage, async_router: router) }

  let(:storage) { RubyReactor.configuration.storage_adapter }
  let(:collections) { [] }
  let(:router) do
    captured = collections
    Class.new do
      define_singleton_method(:perform_map_collection_async) { |**kw| captured << kw }
    end
  end

  let(:parent_context) do
    ctx = RubyReactor::Context.new({ items: [10, 20, 30] }, MapSweepReactor)
    storage.store_context(ctx.context_id, RubyReactor::ContextSerializer.serialize(ctx), "MapSweepReactor")
    ctx
  end
  let(:map_id) { "#{parent_context.context_id}:work" }

  def init_map(count:, **extra)
    storage.initialize_map_operation(
      map_id, count, "MapSweepReactor",
      reactor_class_info: { "type" => "class", "name" => "MapSweepReactor" },
      parent_context_id: parent_context.context_id, step_name: "work", **extra
    )
  end

  def store_result(index, value)
    storage.store_map_result(map_id, index, RubyReactor::ContextSerializer.serialize_value(value), "MapSweepReactor")
  end

  describe "M1: missing element results" do
    before { allow(RubyReactor::Map::Dispatcher).to receive(:requeue_index) }

    it "re-dispatches indices with no stored result and no live element lock" do
      init_map(count: 3)
      store_result(0, 10)
      store_result(1, 20) # index 2 missing

      result = sweeper.run_once
      expect(result[:redispatched]).to eq(1)
      expect(RubyReactor::Map::Dispatcher).to have_received(:requeue_index).with(hash_including("map_id" => map_id), 2)
    end

    it "does not re-dispatch a missing index whose element is still alive (lock held)" do
      init_map(count: 3)
      store_result(0, 10)
      store_result(1, 20)
      RubyReactor::Lock.new("map_element:#{map_id}:2", owner: "live", ttl: 60, auto_extend: false).acquire

      expect(sweeper.run_once[:redispatched]).to eq(0)
      expect(RubyReactor::Map::Dispatcher).not_to have_received(:requeue_index)
    end
  end

  describe "M2: all results present but the parent never resumed" do
    it "re-triggers the collector when nothing is missing and no collector/parent is alive" do
      init_map(count: 3)
      3.times { |i| store_result(i, i * 10) }

      expect(sweeper.run_once[:recollected]).to eq(1)
      expect(collections.first).to include(map_id: map_id, parent_context_id: parent_context.context_id)
    end

    it "does not re-trigger while a collector is already running (collect lock held)" do
      init_map(count: 3)
      3.times { |i| store_result(i, i * 10) }
      RubyReactor::Lock.new("map_collect:#{map_id}", owner: "live", ttl: 60, auto_extend: false).acquire

      expect(sweeper.run_once[:recollected]).to eq(0)
      expect(collections).to be_empty
    end

    it "does not re-trigger while the parent reactor is alive (async lock held)" do
      init_map(count: 3)
      3.times { |i| store_result(i, i * 10) }
      RubyReactor::Lock.new("async:#{parent_context.context_id}", owner: "live", ttl: 60, auto_extend: false).acquire

      expect(sweeper.run_once[:recollected]).to eq(0)
    end

    it "does not re-trigger once the parent already recorded the step result" do
      parent_context.set_result(:work, [10, 20, 30])
      storage.store_context(
        parent_context.context_id, RubyReactor::ContextSerializer.serialize(parent_context), "MapSweepReactor"
      )
      init_map(count: 3)
      3.times { |i| store_result(i, i * 10) }

      expect(sweeper.run_once[:recollected]).to eq(0)
    end
  end

  describe "N1: nested map liveness uses the element lock, not async" do
    it "does not re-trigger while the element-parent is alive (map_element lock held)" do
      init_map(count: 3, parent_is_map_element: true, outer_map_id: "outer:step", outer_index: 5)
      3.times { |i| store_result(i, i * 10) }
      RubyReactor::Lock.new("map_element:outer:step:5", owner: "live", ttl: 60, auto_extend: false).acquire

      expect(sweeper.run_once[:recollected]).to eq(0)
    end
  end
end
