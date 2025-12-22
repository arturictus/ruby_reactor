# frozen_string_literal: true

require "spec_helper"
require "ruby_reactor/storage/redis_adapter"

RSpec.describe RubyReactor::Storage::RedisAdapter do
  let(:redis_url) { "redis://localhost:6780" }
  let(:redis_client) { Redis.new(url: redis_url) }
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

    it "stores unordered result using RPUSH" do
      map_id = "map-123"
      index = 0
      result = { value: 1 }
      reactor_class = "MyReactor"
      key = "reactor:MyReactor:map:map-123:results"

      adapter.store_map_result(map_id, index, result, reactor_class, strict_ordering: false)

      stored_vals = redis_client.lrange(key, 0, -1)
      expect(stored_vals).to eq([result.to_json])
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

    it "retrieves unordered results using LRANGE" do
      map_id = "map-123"
      reactor_class = "MyReactor"
      key = "reactor:MyReactor:map:map-123:results"

      redis_client.rpush(key, { value: 1 }.to_json)
      redis_client.rpush(key, { value: 2 }.to_json)

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
        "retry_count" => 0
      }
      key = "reactor:MyReactor:context:ctx-123"

      redis_client.set(key, data.to_json)

      result = adapter.scan_reactors(pattern: "reactor:*:context:*", count: 10)
      expect(result).to be_an(Array)
      expect(result.first).to include(
        id: context_id,
        class: reactor_class,
        status: "running"
      )
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
