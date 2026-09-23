# frozen_string_literal: true

require "spec_helper"

# US1 (005 quickstart R1): an undo is not dropped because the key it has to
# re-take is busy right now. Rollback waits up to `rollback_wait` (default: the
# lock's `ttl`, or 60 s for a semaphore), and every undo or compensation that
# did not complete is reported on `Failure#rollback_failures`.
RSpec.describe "rollback under contention", :step_coordination do
  let(:run_id) { step_coord_run_id }
  let(:account_id) { SecureRandom.random_number(10**9) }
  let(:key) { "rbc:acct:#{account_id}" }

  def undo_log
    redis.lrange(RbcSupport.log_key(run_id), 0, -1)
  end

  def run_reactor(reactor, hold_seconds: nil)
    reactor.run(run_id: run_id, account_id: account_id, hold_seconds: hold_seconds)
  end

  it "waits for a holder that releases within the rollback wait, then runs the undo" do
    result = run_reactor(RbcReactor, hold_seconds: 0.5)

    expect(result).to be_a(RubyReactor::Failure)
    # `ttl: 1` is the default rollback wait and outlasts the 0.5 s hold; the
    # forward `wait: 0` would not.
    expect(undo_log).to eq(["undo:#{account_id}"])
    expect(result.rollback_failures).to eq([])
  end

  it "reports an undo it could not re-acquire the key for, instead of dropping it silently" do
    result = run_reactor(RbcShortWaitReactor, hold_seconds: 2)

    expect(result).to be_a(RubyReactor::Failure)
    expect(undo_log).to be_empty
    expect(result.rollback_failures).to include(
      hash_including(step: :charge, kind: :undo, key: key, reason: :coordination_unavailable)
    )
    entry = result.rollback_failures.first
    expect(entry[:message]).to include("could not re-acquire lock '#{key}' for rollback of :charge within 0.2s")
  end

  it "waits up to 60 s by default for a semaphore, which has no hold expiry" do
    result = run_reactor(RbcSemaphoreReactor, hold_seconds: 0.5)

    expect(undo_log).to eq(["undo:#{account_id}"])
    expect(result.rollback_failures).to eq([])
  end

  it "reports an undo that raised" do
    result = run_reactor(RbcRaisingUndoReactor)

    expect(result.rollback_failures).to contain_exactly(
      hash_including(step: :charge, kind: :undo, key: nil, reason: :raised, message: "boom")
    )
  end

  it "reports an undo that returned a Failure" do
    result = run_reactor(RbcFailureUndoReactor)

    expect(result.rollback_failures).to contain_exactly(
      hash_including(step: :charge, kind: :undo, reason: :returned_failure, message: "nope")
    )
  end

  it "reports the failing step's own compensation when it returned a Failure" do
    result = RbcCompensateReactor.run(run_id: run_id, account_id: account_id)

    expect(result).to be_a(RubyReactor::Failure)
    expect(result.rollback_failures).to include(
      hash_including(step: :settle, kind: :compensate, reason: :returned_failure, message: "comp-fail")
    )
    # The completed step before it still rolled back.
    expect(undo_log).to eq(["undo:#{account_id}"])
  end

  it "flattens a composed child's rollback failures into the parent's list" do
    result = RbcComposedParentReactor.run(run_id: run_id, account_id: account_id)

    expect(result).to be_a(RubyReactor::Failure)
    expect(result.rollback_failures).to contain_exactly(
      hash_including(step: :charge, kind: :undo, key: key, reason: :coordination_unavailable)
    )
  end

  it "survives serialization, so a background run's stored failure carries it too" do
    result = run_reactor(RbcShortWaitReactor, hold_seconds: 2)

    restored = RubyReactor::Failure.new(JSON.parse(JSON.generate(result.to_h)))

    expect(restored.rollback_failures).to contain_exactly(
      hash_including(step: :charge, kind: :undo, key: key, reason: :coordination_unavailable)
    )
  end
end
