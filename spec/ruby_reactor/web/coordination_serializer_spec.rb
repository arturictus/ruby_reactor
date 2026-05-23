# frozen_string_literal: true

require "spec_helper"
require_relative "../../examples/locking_reactors"
require "ruby_reactor/web/coordination_serializer"

RSpec.describe RubyReactor::Web::CoordinationSerializer do
  let(:adapter) { RubyReactor.configuration.storage_adapter }

  describe ".build" do
    it "returns an empty hash when reactor_class is nil" do
      expect(described_class.build(nil, inputs: {}, context_id: "ctx-1")).to eq({})
    end

    it "returns an empty hash for reactors without coordination config" do
      reactor = Class.new(RubyReactor::Reactor) do
        step :work do
          run { RubyReactor.Success(:ok) }
        end
      end

      result = described_class.build(reactor, inputs: {}, context_id: "ctx-1")
      expect(result).to eq({})
    end

    it "reports a held lock owned by this context" do
      adapter.lock_acquire("lock:user_42", "ctx-abc", 60)

      result = described_class.build(
        SimpleLockReactor,
        inputs: { user_id: 42 },
        context_id: "ctx-abc"
      )

      expect(result[:lock][:key]).to eq("user_42")
      expect(result[:lock][:configured]).to include(ttl: 10, wait: 0, auto_extend: true)
      expect(result[:lock][:state][:held]).to be true
      expect(result[:lock][:state][:owned_by_this_context]).to be true
      expect(result[:lock][:state][:reentrant_count]).to eq(1)
    end

    it "reports a free lock when nothing is held" do
      result = described_class.build(
        SimpleLockReactor,
        inputs: { user_id: 7 },
        context_id: "ctx-xyz"
      )

      expect(result[:lock][:key]).to eq("user_7")
      expect(result[:lock][:state][:held]).to be false
    end

    it "reports a lock held by another context" do
      adapter.lock_acquire("lock:user_99", "other-owner", 60)

      result = described_class.build(
        SimpleLockReactor,
        inputs: { user_id: 99 },
        context_id: "ctx-mine"
      )

      expect(result[:lock][:state][:held]).to be true
      expect(result[:lock][:state][:owned_by_this_context]).to be false
      expect(result[:lock][:state][:owner]).to eq("other-owner")
    end

    it "includes semaphore state for configured reactors" do
      SemaphoreReactor.run

      result = described_class.build(
        SemaphoreReactor,
        inputs: {},
        context_id: "ctx-1"
      )

      expect(result[:semaphore][:key]).to eq("api_limit")
      expect(result[:semaphore][:configured]).to eq(limit: 2, wait: 0)
      expect(result[:semaphore][:state]).to include(
        available: 2,
        held: 0,
        limit: 2
      )
    end

    it "includes rate-limit window counts" do
      2.times { RateLimitedReactor.run(account_id: 5) }

      result = described_class.build(
        RateLimitedReactor,
        inputs: { account_id: 5 },
        context_id: "ctx-1"
      )

      expect(result[:rate_limit][:key]).to eq("api:5")
      expect(result[:rate_limit][:state].size).to eq(1)
      expect(result[:rate_limit][:state].first).to include(
        name: "second",
        limit: 3,
        count: 2
      )
    end

    it "includes period bucket state" do
      PeriodicReactor.run(org_id: 10)

      result = described_class.build(
        PeriodicReactor,
        inputs: { org_id: 10 },
        context_id: "ctx-1"
      )

      expect(result[:period][:key]).to eq("daily_report:10")
      expect(result[:period][:bucket_key]).to start_with("period:daily_report:10:")
      expect(result[:period][:state][:marked]).to be true
    end

    it "includes all coordination primitives for combined reactors" do
      LockedPeriodicReactor.run(id: 1)

      result = described_class.build(
        LockedPeriodicReactor,
        inputs: { id: 1 },
        context_id: "ctx-1"
      )

      expect(result.keys).to contain_exactly(:lock, :period)
    end
  end
end
