# frozen_string_literal: true

require "spec_helper"
require "ruby_reactor/storage/redis_adapter"

RSpec.describe RubyReactor::Storage::RedisAdapter do
  let(:redis_url) { REDIS_TEST_URL }
  let(:redis_client) { redis } # from spec_helper's RedisHelpers
  let(:adapter) { described_class.new(url: redis_url) }

  describe "#store_context" do
    it "stores context using JSON.SET" do
      context_id = "ctx-123"
      reactor_class = "MyReactor"
      data = { foo: "bar" }.to_json
      key = "reactor:MyReactor:context:ctx-123"

      adapter.store_context(context_id, data, reactor_class)

      # Verify directly in Redis
      stored_data = redis_client.get(key)
      expect(stored_data).to eq(data)

      # Verify TTL (approximate)
      ttl = redis_client.ttl(key)
      expect(ttl).to be_within(5).of(86_400)
    end
  end

  describe "#retrieve_context" do
    it "retrieves context using JSON.GET" do
      context_id = "ctx-123"
      reactor_class = "MyReactor"
      key = "reactor:MyReactor:context:ctx-123"
      data = { "foo" => "bar" }

      # Setup
      redis_client.set(key, data.to_json)

      result = adapter.retrieve_context(context_id, reactor_class)
      expect(result).to eq(data)
    end

    it "returns nil if context not found" do
      context_id = "ctx-123"
      reactor_class = "MyReactor"

      result = adapter.retrieve_context(context_id, reactor_class)
      expect(result).to be_nil
    end
  end

  describe "#store_map_result" do
    it "stores ordered result using HSET" do
      map_id = "map-123"
      index = 0
      result = { value: 1 }
      reactor_class = "MyReactor"
      key = "reactor:MyReactor:map:map-123:results"

      adapter.store_map_result(map_id, index, result, reactor_class, strict_ordering: true)

      stored_val = redis_client.hget(key, "0")
      expect(stored_val).to eq(result.to_json)
    end

    it "stores unordered results index-keyed (HSET) too, for idempotent recovery" do
      # Durable map storage is always index-keyed regardless of strict_ordering
      # (Phase 5), so missing-index recovery and idempotent re-dispatch apply
      # uniformly. Re-running an index overwrites its slot, never duplicates.
      map_id = "map-123"
      index = 2
      result = { value: 1 }
      reactor_class = "MyReactor"
      key = "reactor:MyReactor:map:map-123:results"

      adapter.store_map_result(map_id, index, result, reactor_class, strict_ordering: false)
      adapter.store_map_result(map_id, index, result, reactor_class, strict_ordering: false) # idempotent

      expect(redis_client.type(key)).to eq("hash")
      expect(redis_client.hget(key, "2")).to eq(result.to_json)
      expect(redis_client.hlen(key)).to eq(1)
    end
  end

  describe "#retrieve_map_results" do
    it "retrieves ordered results using HGETALL and sorts by index" do
      map_id = "map-123"
      reactor_class = "MyReactor"
      key = "reactor:MyReactor:map:map-123:results"

      redis_client.hset(key, "1", { value: 2 }.to_json)
      redis_client.hset(key, "0", { value: 1 }.to_json)

      result = adapter.retrieve_map_results(map_id, reactor_class, strict_ordering: true)
      expect(result).to eq([{ "value" => 1 }, { "value" => 2 }])
    end

    it "retrieves unordered results from the index-keyed hash, sorted by index" do
      map_id = "map-123"
      reactor_class = "MyReactor"
      key = "reactor:MyReactor:map:map-123:results"

      redis_client.hset(key, "1", { value: 2 }.to_json)
      redis_client.hset(key, "0", { value: 1 }.to_json)

      result = adapter.retrieve_map_results(map_id, reactor_class, strict_ordering: false)
      expect(result).to eq([{ "value" => 1 }, { "value" => 2 }])
    end
  end

  describe "#scan_reactors" do
    it "scans and returns reactors" do
      context_id = "ctx-123"
      reactor_class = "MyReactor"
      data = {
        "context_id" => context_id,
        "reactor_class" => reactor_class,
        "started_at" => Time.now.to_s,
        "current_step" => "step1",
        "retry_count" => 0,
        "failure_reason" => { "step_name" => "step1", "exception_class" => "RuntimeError" }
      }
      key = "reactor:MyReactor:context:ctx-123"

      redis_client.set(key, data.to_json)

      result = adapter.scan_reactors(pattern: "reactor:*:context:*", count: 10)
      expect(result).to be_an(Array)
      expect(result.first).to include(
        id: context_id,
        class: reactor_class,
        status: "running",
        failure: { "step_name" => "step1", "exception_class" => "RuntimeError" }
      )
    end

    it "includes retried top-level runs but excludes nested child contexts" do
      nested_id = "ctx-nested"
      retried_id = "ctx-retried"
      reactor_class = "MyReactor"

      redis_client.set(
        "reactor:MyReactor:context:#{nested_id}",
        {
          "context_id" => nested_id,
          "reactor_class" => reactor_class,
          "started_at" => Time.now.to_s,
          "parent_context_id" => "ctx-parent"
        }.to_json
      )

      redis_client.set(
        "reactor:MyReactor:context:#{retried_id}",
        {
          "context_id" => retried_id,
          "reactor_class" => reactor_class,
          "started_at" => Time.now.to_s,
          "retried_from_id" => "ctx-failed",
          "retry_count" => 1,
          "status" => "running"
        }.to_json
      )

      result = adapter.scan_reactors(pattern: "reactor:*:context:*", count: 10)

      expect(result.map { |item| item[:id] }).to include(retried_id)
      expect(result.map { |item| item[:id] }).not_to include(nested_id)
    end

    it "excludes async_step Step Result Records, which glob-match the same 'reactor:*:context:*' pattern" do
      context_id = "ctx-with-async-step"
      reactor_class = "MyReactor"

      redis_client.set(
        "reactor:#{reactor_class}:context:#{context_id}",
        {
          "context_id" => context_id,
          "reactor_class" => reactor_class,
          "started_at" => Time.now.to_s,
          "retry_count" => 0
        }.to_json
      )
      redis_client.set(
        "reactor:#{reactor_class}:context:#{context_id}:step_result:send_email",
        { "status" => "dispatched", "dispatched_at" => Time.now.to_s }.to_json
      )

      result = adapter.scan_reactors(pattern: "reactor:*:context:*", count: 10)

      expect(result.map { |item| item[:id] }).to eq([context_id])
      expect(result).to all(satisfy { |item| !item[:class].nil? })
    end
  end

  describe "#find_context_by_id" do
    it "finds context by id regardless of reactor class" do
      context_id = "ctx-123"
      data = { "context_id" => context_id, "foo" => "bar" }
      key = "reactor:MyReactor:context:ctx-123"

      redis_client.set(key, data.to_json)

      result = adapter.find_context_by_id(context_id)
      expect(result).to eq(data)
    end

    it "returns nil if context not found" do
      result = adapter.find_context_by_id("non-existent")
      expect(result).to be_nil
    end
  end

  # 009 DM §2, §3: map metadata knows its owner run, batch size and policy.
  describe "#initialize_map_operation" do
    it "stores the owner ids, batch_size and atomic" do
      adapter.initialize_map_operation("p1:m", 3, "P", reactor_class_info: { "type" => "class", "name" => "E" },
                                                       owner_context_id: "root", owner_reactor_class_name: "Root",
                                                       batch_size: 2, atomic: true)

      expect(adapter.retrieve_map_metadata("p1:m", "P")).to include(
        "owner_context_id" => "root", "owner_reactor_class_name" => "Root", "batch_size" => 2, "atomic" => true
      )
    end
  end

  describe "#claim_map_owner_signal" do
    it "claims once per map" do
      expect(adapter.claim_map_owner_signal("p1:m", "P")).to be(true)
      expect(adapter.claim_map_owner_signal("p1:m", "P")).to be(false)
      expect(redis_client.ttl("reactor:P:map:p1:m:owner_signalled")).to be_within(5).of(86_400)
    end
  end

  # 009 DM §5: the map rollback records.
  describe "map rollback records" do
    before { %w[a b c d e].each { |id| adapter.store_map_element_context_id("p1:m", id, "P") } }

    it "reads element ids by tail position, anchored at the total the rollback started with" do
      expect(adapter.count_map_element_context_ids("p1:m", "P")).to eq(5)
      expect(adapter.retrieve_map_element_context_ids_from_tail("p1:m", "P", 0, 2, total: 5)).to eq(%w[e d])
      expect(adapter.retrieve_map_element_context_ids_from_tail("p1:m", "P", 3, 5, total: 5)).to eq(%w[b a])
      adapter.store_map_element_context_id("p1:m", "late", "P")
      expect(adapter.retrieve_map_element_context_ids_from_tail("p1:m", "P", 0, 1, total: 5)).to eq(%w[e])
      expect(adapter.retrieve_map_element_context_ids_from_tail("p1:m", "P", 5, 2, total: 5)).to eq([])
    end

    it "starts a rollback once and claims positions clipped to the total" do
      created, meta = adapter.start_map_rollback("p1:m", "P", total: 5, batch_size: 2, step_name: "m",
                                                              reactor_class_info: { "type" => "class", "name" => "E" })
      again, = adapter.start_map_rollback("p1:m", "P", total: 9, batch_size: 9, step_name: "m",
                                                       reactor_class_info: {})

      expect([created, again]).to eq([true, false])
      expect(meta).to include("total" => 5, "batch_size" => 2,
                              "reactor_class_info" => { "type" => "class", "name" => "E" })
      expect(adapter.retrieve_map_rollback_metadata("p1:m", "P")["total"]).to eq(5)
      expect(adapter.claim_map_rollback_positions("p1:m", "P", 2)).to eq(0...2)
      expect(adapter.claim_map_rollback_positions("p1:m", "P", 2)).to eq(2...4)
      expect(adapter.claim_map_rollback_positions("p1:m", "P", 2)).to eq(4...5)
      expect(adapter.claim_map_rollback_positions("p1:m", "P", 2).to_a).to be_empty
    end

    it "stores outcomes idempotently and summarizes them" do
      adapter.start_map_rollback("p1:m", "P", total: 3, batch_size: 3, step_name: "m", reactor_class_info: {})
      adapter.store_map_rollback_outcome("p1:m", "P", 0, { "index" => 2, "outcome" => "undone", "failures" => [] })
      adapter.store_map_rollback_outcome("p1:m", "P", 0, { "index" => 2, "outcome" => "undone", "failures" => [] })
      adapter.store_map_rollback_outcome("p1:m", "P", 1, { "index" => 1, "outcome" => "failed", "failures" => [{}] })
      adapter.store_map_rollback_outcome("p1:m", "P", 2, { "index" => nil, "outcome" => "context_unavailable" })

      expect(adapter.count_map_rollback_outcomes("p1:m", "P")).to eq(3)
      outcomes = []
      adapter.each_map_rollback_outcome("p1:m", "P") { |position, outcome| outcomes << [position, outcome["outcome"]] }
      expect(outcomes).to contain_exactly([0, "undone"], [1, "failed"], [2, "context_unavailable"])
      expect(adapter.map_rollback_indexes_seen("p1:m", "P", [0, 1, 2])).to eq([false, true, true])
      expect(adapter.map_rollback_summary("p1:m", "P")).to eq(total: 3, settled: 3, outstanding: 0, failed: 2)
    end

    it "gates the owner signal on the hand-off, and claims it once" do
      expect(adapter.map_rollback_handed_off?("p1:m", "P")).to be(false)
      adapter.mark_map_rollback_handed_off("p1:m", "P")
      expect(adapter.map_rollback_handed_off?("p1:m", "P")).to be(true)
      expect(adapter.claim_map_rollback_signal("p1:m", "P")).to be(true)
      expect(adapter.claim_map_rollback_signal("p1:m", "P")).to be(false)
    end

    it "lists started rollbacks for the sweeper, and scan_maps skips them" do
      adapter.initialize_map_operation("p1:m", 5, "P", reactor_class_info: {})
      adapter.start_map_rollback("p1:m", "P", total: 5, batch_size: 2, step_name: "m", reactor_class_info: {})

      expect(adapter.scan_map_rollbacks(count: 10)).to contain_exactly(
        a_hash_including("map_id" => "p1:m", "parent_reactor_class_name" => "P", "total" => 5)
      )
      expect(adapter.scan_maps(count: 10).map { |meta| meta["map_id"] }).to eq(["p1:m"])
      expect(adapter.map_rollback_summary("p2:m", "P")).to be_nil
    end
  end
end
