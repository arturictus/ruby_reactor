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
end
