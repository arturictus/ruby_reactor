# frozen_string_literal: true

require "spec_helper"
require "ruby_reactor/storage/redis_adapter"

RSpec.describe RubyReactor::Storage::RedisAdapter do
  let(:redis_client) { instance_double(Redis) }
  let(:adapter) { described_class.new(url: "redis://localhost:6379") }

  before do
    allow(Redis).to receive(:new).and_return(redis_client)
  end

  describe "#store_context" do
    it "stores context using JSON.SET" do
      context_id = "ctx-123"
      reactor_class = "MyReactor"
      data = { foo: "bar" }
      key = "reactor:MyReactor:context:ctx-123"

      expect(redis_client).to receive(:call).with("JSON.SET", key, ".", data.to_json)
      expect(redis_client).to receive(:expire).with(key, 86_400)

      adapter.store_context(context_id, data, reactor_class)
    end
  end

  describe "#retrieve_context" do
    it "retrieves context using JSON.GET" do
      context_id = "ctx-123"
      reactor_class = "MyReactor"
      key = "reactor:MyReactor:context:ctx-123"
      data = { "foo" => "bar" }

      allow(redis_client).to receive(:call).with("JSON.GET", key).and_return(data.to_json)

      result = adapter.retrieve_context(context_id, reactor_class)
      expect(result).to eq(data)
    end

    it "returns nil if context not found" do
      context_id = "ctx-123"
      reactor_class = "MyReactor"
      key = "reactor:MyReactor:context:ctx-123"

      allow(redis_client).to receive(:call).with("JSON.GET", key).and_return(nil)

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

      expect(redis_client).to receive(:hset).with(key, "0", result.to_json)
      expect(redis_client).to receive(:expire).with(key, 86_400)

      adapter.store_map_result(map_id, index, result, reactor_class, strict_ordering: true)
    end

    it "stores unordered result using RPUSH" do
      map_id = "map-123"
      index = 0
      result = { value: 1 }
      reactor_class = "MyReactor"
      key = "reactor:MyReactor:map:map-123:results"

      expect(redis_client).to receive(:rpush).with(key, result.to_json)
      expect(redis_client).to receive(:expire).with(key, 86_400)

      adapter.store_map_result(map_id, index, result, reactor_class, strict_ordering: false)
    end
  end

  describe "#retrieve_map_results" do
    it "retrieves ordered results using HGETALL and sorts by index" do
      map_id = "map-123"
      reactor_class = "MyReactor"
      key = "reactor:MyReactor:map:map-123:results"
      data = {
        "1" => { value: 2 }.to_json,
        "0" => { value: 1 }.to_json
      }

      allow(redis_client).to receive(:hgetall).with(key).and_return(data)

      result = adapter.retrieve_map_results(map_id, reactor_class, strict_ordering: true)
      expect(result).to eq([{ "value" => 1 }, { "value" => 2 }])
    end

    it "retrieves unordered results using LRANGE" do
      map_id = "map-123"
      reactor_class = "MyReactor"
      key = "reactor:MyReactor:map:map-123:results"
      data = [{ value: 1 }.to_json, { value: 2 }.to_json]

      allow(redis_client).to receive(:lrange).with(key, 0, -1).and_return(data)

      result = adapter.retrieve_map_results(map_id, reactor_class, strict_ordering: false)
      expect(result).to eq([{ "value" => 1 }, { "value" => 2 }])
    end
  end
end
