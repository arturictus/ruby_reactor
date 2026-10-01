# frozen_string_literal: true

require "spec_helper"

# 009 R-04: a construct's rollback can hand off. The run becomes
# `rolling_back`, its undo stack is the resume cursor, and its Worker resumes
# the rollback later and finishes with the Failure an inline rollback gives.
# The construct here is a stub: its undo hands off while `stub:pending` exists.
module ResumeRollbackSpec
  PENDING = "stub:pending"

  class HandsOffOnce < RubyReactor::Step
    def run = Success("h")

    def undo
      if Redis.new(url: REDIS_TEST_URL).exists?(PENDING)
        raise RubyReactor::Error::RollbackHandedOff.new(map_id: "stub", reactor_class_name: "Stub")
      end

      RollbackRecorder.record("undo:h")
      Success()
    end
  end

  class Parent < RollbackRecorder::Reactor
    background all: true
    recording_step :a
    step(:h, HandsOffOnce) { wait_for :a }
    recording_step :b, after: :h, fail: true
  end
end

RSpec.describe "Executor#resume_rollback" do
  let(:worker) { RubyReactor::Adapters::Sidekiq::Worker }

  def run_through_worker
    id = ResumeRollbackSpec::Parent.run({}).execution_id
    job = worker.jobs.shift
    worker.new.perform(*job["args"])
    id
  end

  before { RollbackRecorder.reset! }
  after { redis.del(ResumeRollbackSpec::PENDING) }

  it "hands off as rolling_back, then resumes to the same Failure as an inline rollback" do
    redis.set(ResumeRollbackSpec::PENDING, "1")
    id = run_through_worker

    context = ResumeRollbackSpec::Parent.find(id).context
    expect(context.status.to_s).to eq("rolling_back")
    expect(RollbackRecorder.log).not_to include("undo:a")
    expect(context.rollback).to include("trigger" => "failure", "step" => "b", "compensated" => true,
                                        "failures" => [])
    expect(context.rollback["failure"]).not_to be_nil

    redis.del(ResumeRollbackSpec::PENDING)
    worker.new.perform(id, ResumeRollbackSpec::Parent.name)

    resumed = ResumeRollbackSpec::Parent.find(id)
    expect(RollbackRecorder.log).to end_with("compensate:b", "undo:h", "undo:a")
    expect(resumed.context.status.to_s).to eq("failed")
    expect(resumed.context.rollback).to be_nil

    RollbackRecorder.reset!
    plain = ResumeRollbackSpec::Parent.find(run_through_worker).result
    shape = lambda do |failure|
      [failure.error, failure.step_name.to_s, failure.exception_class, failure.rollback_failures, failure.inputs]
    end
    expect(shape.call(resumed.result)).to eq(shape.call(plain))
  end

  it "is a control signal, never a failure" do
    expect(RubyReactor::Error::Rescuable === RubyReactor::Error::RollbackHandedOff.new(map_id: "x")) # rubocop:disable Style/CaseEquality
      .to be(false)
  end

  it "never marks the run aborted" do
    redis.set(ResumeRollbackSpec::PENDING, "1")
    id = run_through_worker

    statuses = ResumeRollbackSpec::Parent.find(id).context.execution_trace.map { |entry| entry[:status] }
    expect(ResumeRollbackSpec::Parent.find(id).context.status.to_s).not_to eq("aborted")
    expect(statuses).not_to include(:aborted, "aborted")
  end
end
