# frozen_string_literal: true

require "spec_helper"
require_relative "../../examples/locking_reactors"

RSpec.describe "Locking Integration" do
  let(:redis) { Redis.new(url: "redis://localhost:6780") }

  before do
    redis.flushdb
  end

  describe "Exclusive Locks" do
    it "succeeds when lock is available" do
      result = SimpleLockReactor.run(user_id: 1)
      expect(result).to be_success
      expect(result.value).to eq(process: { processed: true })
    end

    it "supports re-entrancy for the same execution" do
      result = NestedLockReactor.run(user_id: 1)
      expect(result).to be_success
      expect(result.value).to eq(parent: { child: { child_done: true } })
    end

    it "fails synchronously when lock is held by someone else" do
      # Manually hold the lock
      redis.hset("lock:user_1", "owner", "other_guy")
      redis.hset("lock:user_1", "count", "1")

      expect do
        SimpleLockReactor.run(user_id: 1)
      end.to raise_error(RubyReactor::Lock::AcquisitionError)
    end

    it "reschedules asynchronously when lock is held" do
      # Manually hold the lock
      redis.hset("lock:user_1", "owner", "other_guy")
      redis.hset("lock:user_1", "count", "1")

      # Stub SidekiqWorker to capture rescheduling
      expect(RubyReactor::SidekiqWorkers::Worker).to receive(:perform_in).with(5, any_args)

      # Call the worker's perform method with a serialized context
      context = RubyReactor::Context.new({ user_id: 1 }, SimpleLockReactor)
      serialized_context = RubyReactor::ContextSerializer.serialize(context)

      worker = RubyReactor::SidekiqWorkers::Worker.new
      worker.perform(serialized_context, "SimpleLockReactor")
    end
  end

  describe "Semaphores" do
    it "succeeds when semaphore capacity is available" do
      result = SemaphoreReactor.run(limit_id: 1)
      expect(result).to be_success
    end

    it "fails when semaphore capacity is exhausted" do
      # Capacity is 2
      # Semaphore.new init pushes limit tokens during acquire if not exists.

      s = RubyReactor::Semaphore.new("api_limit", limit: 2)
      s.acquire # 1 left
      s.acquire # 0 left

      expect do
        SemaphoreReactor.run(limit_id: 1)
      end.to raise_error(RubyReactor::Semaphore::AcquisitionError)
    end
  end
end
