# frozen_string_literal: true

require "spec_helper"

# US3 (F-03, F-13): every exception after completed work, except an
# interruption, rolls the completed work back, and the failure names the step
# it happened in (008 R-16). F-06 went with `where`/`guard` (R-15).
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

  # Not a StandardError, and not an interruption: reactor code's own failure (R-16).
  class Crash < Exception; end # rubocop:disable Lint/InheritException

  def self.body_raises(error)
    Class.new(RollbackRecorder::Reactor) do
      recording_step :a
      recording_step(:b, after: :a) do
        run do |_inputs, _ctx|
          RollbackRecorder.record("run:b")
          raise error
        end
      end
    end
  end

  class NoRunStep < RubyReactor::Step; end

  class MissingRun < RollbackRecorder::Reactor
    recording_step :a
    step(:b, NoRunStep) { wait_for :a }
  end

  class TransformCrashes < RollbackRecorder::Reactor
    recording_step :a
    recording_step(:b, after: :a) { argument :x, result(:a), transform: ->(_value) { raise Crash, "bad" } }
  end

  class UndoCrashes < RollbackRecorder::Reactor
    recording_step :a
    recording_step(:b, after: :a) do
      undo do |_value, _inputs, _ctx|
        RollbackRecorder.record("undo:b")
        raise Crash, "undo crashed"
      end
    end
    recording_step :c, after: :b, fail: true
  end

  class CompensateCrashes < RollbackRecorder::Reactor
    recording_step :a
    recording_step(:b, after: :a, fail: true) do
      compensate do |_error, _inputs, _ctx|
        RollbackRecorder.record("compensate:b")
        raise Crash, "compensate crashed"
      end
    end
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

  describe "exceptions that are not StandardError (R-16)" do
    {
      "a custom Exception subclass" => [FailureRollbackSpec::Crash.new("custom"), "FailureRollbackSpec::Crash"],
      "a SystemStackError" => [SystemStackError.new("stack level too deep"), "SystemStackError"]
    }.each do |label, (error, class_name)|
      it "compensates the step and undoes completed work when its body raises #{label}" do
        result = FailureRollbackSpec.body_raises(error).run({})

        expect(result).to be_failure
        expect(RollbackRecorder.log).to eq(%w[run:a run:b compensate:b undo:a])
        expect(result.step_name).to eq(:b)
        expect(result.exception_class).to eq(class_name)
      end
    end

    it "rolls back a step class that does not implement `run` (NotImplementedError)" do
      result = FailureRollbackSpec::MissingRun.run({})

      expect(result).to be_failure
      expect(RollbackRecorder.log).to eq(%w[run:a undo:a])
      expect(result.step_name).to eq(:b)
      expect(result.exception_class).to eq("NotImplementedError")
    end

    it "treats an argument transform that raises one as a never-started failure" do
      result = FailureRollbackSpec::TransformCrashes.run({})

      expect(RollbackRecorder.log).to eq(%w[run:a undo:a])
      expect(result.step_name).to eq(:b)
      expect(result.exception_class).to eq("FailureRollbackSpec::Crash")
    end

    it "records an undo that raises one as a rollback failure and keeps undoing (FR-028)" do
      result = FailureRollbackSpec::UndoCrashes.run({})

      expect(RollbackRecorder.log).to eq(%w[run:a run:b run:c compensate:c undo:b undo:a])
      expect(result.rollback_failures.map { |f| [f[:step], f[:kind]] }).to eq([%i[b undo]])
    end

    it "keeps undoing when a compensate raises one, and names the step (FR-028)" do
      result = FailureRollbackSpec::CompensateCrashes.run({})

      expect(RollbackRecorder.log).to eq(%w[run:a run:b compensate:b undo:a])
      expect(result).to be_failure
      expect(result.step_name).to eq(:b)
    end
  end
end
