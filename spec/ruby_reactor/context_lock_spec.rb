# frozen_string_literal: true

require "spec_helper"

# Phase 1: the per-context liveness lock (`async:<id>`) serializes duplicate
# deliveries of the same root context and is the sweeper's "worker alive" signal.
# Owner is a fresh UUID per execution (never the context_id), so a duplicate from
# a different worker is blocked rather than reentrantly admitted.
class CtxLockReactor < RubyReactor::Reactor
  @runs = 0
  class << self; attr_accessor :runs; end

  input :n

  step :work do
    argument :n, input(:n)
    run do |args, _ctx|
      CtxLockReactor.runs += 1
      RubyReactor.Success(args[:n])
    end
  end
end

RSpec.describe "Per-context liveness lock" do
  let(:storage) { RubyReactor.configuration.storage_adapter }

  before { CtxLockReactor.runs = 0 }

  # A resumable context (current_step set), persisted, ready for a worker resume.
  def resumable_context
    context = RubyReactor::Context.new({ n: 1 }, CtxLockReactor)
    context.current_step = :work
    storage.store_context(
      context.context_id, RubyReactor::ContextSerializer.serialize(context), "CtxLockReactor"
    )
    context
  end

  def hold_async_lock(context_id, owner:)
    lock = RubyReactor::Lock.new("async:#{context_id}", owner: owner, ttl: 60, auto_extend: false)
    lock.acquire
    lock
  end

  it "blocks a duplicate resume while a live original holds the lock" do
    context = resumable_context
    hold_async_lock(context.context_id, owner: "live-original")

    executor = RubyReactor::Executor.new(CtxLockReactor, {}, context)
    expect { executor.resume_execution }.to raise_error(RubyReactor::Lock::ContextLockContention)
    expect(CtxLockReactor.runs).to eq(0) # the in-flight step never ran twice
  end

  it "does not persist on a lost-lock contention (must not clobber the original's checkpoint)" do
    context = resumable_context
    hold_async_lock(context.context_id, owner: "live-original")

    executor = RubyReactor::Executor.new(CtxLockReactor, {}, context)
    expect { executor.resume_execution }.to raise_error(RubyReactor::Lock::ContextLockContention)
    expect(executor.skip_context_persist?).to be true
  end

  it "uses a per-execution owner, not the context_id (reentrancy would defeat the guard)" do
    context = resumable_context
    # Hold the lock with the context_id AS the owner. If the executor reused the
    # context_id as its owner, this would reentrantly admit the duplicate. It must
    # still be blocked — proving the owner is a fresh per-execution UUID.
    hold_async_lock(context.context_id, owner: context.context_id)

    executor = RubyReactor::Executor.new(CtxLockReactor, {}, context)
    expect { executor.resume_execution }.to raise_error(RubyReactor::Lock::ContextLockContention)
  end

  it "succeeds once the dead holder's lock has expired" do
    context = resumable_context
    lock = hold_async_lock(context.context_id, owner: "dead-worker")
    lock.release # simulate the lock expiring after the worker died

    executor = RubyReactor::Executor.new(CtxLockReactor, {}, context)
    executor.resume_execution
    expect(CtxLockReactor.runs).to eq(1)
    expect(redis.exists?("lock:async:#{context.context_id}")).to be false # released in ensure
  end

  it "releases the lock in the ensure path after a normal resume" do
    context = resumable_context
    executor = RubyReactor::Executor.new(CtxLockReactor, {}, context)
    executor.resume_execution

    expect(redis.exists?("lock:async:#{context.context_id}")).to be false
  end
end
