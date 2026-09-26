# frozen_string_literal: true

require "spec_helper"

# US3 (F-03, F-06, F-13): every standard error after completed work rolls the
# completed work back, and the failure names the step it happened in.
module FailureRollbackSpec
  RAISES = ->(_value) { raise ArgumentError, "bad transform" }

  class TransformRaises < RollbackRecorder::Reactor
    recording_step :a
    recording_step(:b, after: :a) { argument :x, result(:a), transform: RAISES }
  end

  class PathRaises < RollbackRecorder::Reactor
    # "a-value"[:missing] raises TypeError.
    recording_step :a
    recording_step(:b, after: :a) { argument :x, result(:a, :missing) }
  end

  class WhereRaises < RollbackRecorder::Reactor
    recording_step :a
    recording_step(:b, after: :a) do
      where do |_ctx|
        RollbackRecorder.record("where:b")
        raise "condition exploded"
      end
    end
  end

  class GuardRaises < RollbackRecorder::Reactor
    recording_step :a
    recording_step(:b, after: :a) { guard { |_ctx| raise "guard exploded" } }
  end

  class RetriedWhereRaises < RollbackRecorder::Reactor
    recording_step :a
    recording_step(:b, after: :a) do
      retries max_attempts: 3, base_delay: 0
      where do |_ctx|
        RollbackRecorder.record("where:b")
        raise "condition exploded"
      end
    end
  end

  class CheckpointRaises < RollbackRecorder::Reactor
    recording_step :a
    recording_step :b, after: :a
  end

  class CompensateRaises < RollbackRecorder::Reactor
    recording_step :a
    recording_step :b, after: :a, fail: true, compensate_raises: true
  end

  class HandoffTransformRaises < RollbackRecorder::Reactor
    recording_step :a
    recording_step(:b, after: :a) { argument :x, result(:a), transform: RAISES }
    background before: :b
  end

  class UnitTransformRaises < RollbackRecorder::Reactor
    recording_step :a
    recording_step(:u, kind: :async_step, after: :a) { argument :x, result(:a), transform: RAISES }
  end
end

RSpec.describe "rollback on failures outside a step body" do
  let(:storage) { RubyReactor.configuration.storage_adapter }

  it "undoes completed steps and names the step when an argument transform raises (S-plain-07)" do
    result = FailureRollbackSpec::TransformRaises.run({})

    expect(RollbackRecorder.log).to eq(%w[run:a undo:a])
    expect(result).to be_failure
    expect(result.step_name).to eq(:b)
    expect(result.reactor_name).to eq("FailureRollbackSpec::TransformRaises")
    expect(result.exception_class).to eq("ArgumentError")
  end

  it "does the same when a result path raises" do
    result = FailureRollbackSpec::PathRaises.run({})

    expect(RollbackRecorder.log).to eq(%w[run:a undo:a])
    expect(result.step_name).to eq(:b)
    expect(result.exception_class).to eq("TypeError")
  end

  it "does not compensate a step whose `where` raises (S-edge-04)" do
    result = FailureRollbackSpec::WhereRaises.run({})

    expect(RollbackRecorder.log).to eq(%w[run:a where:b undo:a])
    expect(result.step_name).to eq(:b)
  end

  it "does not compensate a step whose `guard` raises" do
    result = FailureRollbackSpec::GuardRaises.run({})

    expect(RollbackRecorder.log).to eq(%w[run:a undo:a])
    expect(result.step_name).to eq(:b)
  end

  it "does not retry a raising condition" do
    FailureRollbackSpec::RetriedWhereRaises.run({})

    expect(RollbackRecorder.log.count("where:b")).to eq(1)
    expect(RollbackRecorder.log).to eq(%w[run:a where:b undo:a])
  end

  it "rolls back on a StandardError raised outside any step body (FR-016)" do
    calls = 0
    allow_any_instance_of(RubyReactor::Executor).to receive(:checkpoint!).and_wrap_original do |original, *args, **kw|
      calls += 1
      raise "checkpoint store unavailable" if calls == 1

      original.call(*args, **kw)
    end

    result = FailureRollbackSpec::CheckpointRaises.run({})

    expect(RollbackRecorder.log).to eq(%w[run:a undo:a])
    expect(result).to be_failure
    expect(result.reactor_name).to eq("FailureRollbackSpec::CheckpointRaises")
    expect(result.exception_class).to eq("RuntimeError")
  end

  it "names the step when its compensation raises (FR-017)" do
    result = FailureRollbackSpec::CompensateRaises.run({})

    expect(RollbackRecorder.log).to eq(%w[run:a run:b compensate:b undo:a])
    expect(result.step_name).to eq(:b)
    expect(result.reactor_name).to eq("FailureRollbackSpec::CompensateRaises")
  end

  for_each_async_backend do
    it "applies the same rule in the worker after a `background before:` hand-off" do
      id = FailureRollbackSpec::HandoffTransformRaises.run({}).execution_id
      RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs

      result = FailureRollbackSpec::HandoffTransformRaises.find(id).result
      expect(RollbackRecorder.log).to eq(%w[run:a undo:a])
      expect(result.step_name.to_s).to eq("b")
    end

    it "records an async_step's argument failure as non-retryable and never compensates it" do
      id = FailureRollbackSpec::UnitTransformRaises.run({}).execution_id
      RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs

      record = storage.retrieve_step_result(id, :u, "FailureRollbackSpec::UnitTransformRaises")
      failure = RubyReactor::Failure.new(RubyReactor::ContextSerializer.deserialize_value(record["result"]))
      expect(failure.step_name.to_s).to eq("u")
      expect(failure.retryable?).to be(false)
      expect(RollbackRecorder.log).not_to include("compensate:u")
    end
  end
end
