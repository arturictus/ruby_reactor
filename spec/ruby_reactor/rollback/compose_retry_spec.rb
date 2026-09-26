# frozen_string_literal: true

require "spec_helper"

# US2 (F-02): a compose retry after a failed attempt starts a fresh child; a
# park/resume still resumes.
module ComposeRetrySpec
  # c1 returns how many times it has run, so a result can say which attempt it came from.
  COUNTED_C1 = proc do
    run do |_inputs, _ctx|
      RollbackRecorder.record("run:child.c1")
      RubyReactor.Success(RollbackRecorder.counters["c1 runs"] += 1)
    end
  end

  class ChildFailsOnce < RollbackRecorder::Reactor
    tag "child"
    recording_step(:c1, &COUNTED_C1)
    recording_step :c2, after: :c1, fail: 1
  end

  class Retried < RollbackRecorder::Reactor
    compose(:child, ChildFailsOnce) { retries max_attempts: 2, base_delay: 0 }
  end

  class RetriedThenFails < RollbackRecorder::Reactor
    compose(:child, ChildFailsOnce) { retries max_attempts: 2, base_delay: 0 }
    recording_step :b, after: :child, fail: true
  end

  class ChildInnerRetries < RollbackRecorder::Reactor
    tag "child"
    recording_step :c1
    recording_step(:c2, after: :c1, fail: true) { retries max_attempts: 2, base_delay: 0 }
  end

  class RetriedInnerRetries < RollbackRecorder::Reactor
    compose(:child, ChildInnerRetries) { retries max_attempts: 2, base_delay: 0 }
  end

  class ChildUndoFails < RollbackRecorder::Reactor
    tag "child"
    recording_step :c1, undo_fails: true
    recording_step :c2, after: :c1, fail: 1
  end

  class RetriedUndoFails < RollbackRecorder::Reactor
    compose(:child, ChildUndoFails) { retries max_attempts: 2, base_delay: 0 }
  end

  class RetriedInWorker < RollbackRecorder::Reactor
    background all: true
    compose(:child, ChildFailsOnce) { retries max_attempts: 2, base_delay: 0 }
  end

  class ParkingStep < RubyReactor::Step
    input :key

    with_lock { |a| "compose_retry:park:#{a[:key]}" }

    def run
      RollbackRecorder.record("run:child.c2")
      Success(:ok)
    end
  end

  class ParkingChild < RollbackRecorder::Reactor
    tag "child"
    input :key
    recording_step :c1
    step :c2, ParkingStep do
      argument :key, input(:key)
      wait_for :c1
    end
  end

  class ParkingParent < RollbackRecorder::Reactor
    background all: true
    input :key
    compose(:child, ParkingChild) do
      argument :key, input(:key)
      retries max_attempts: 2, base_delay: 0
    end
  end
end

RSpec.describe "retrying a composed reactor" do
  let(:storage) { RubyReactor.configuration.storage_adapter }
  let(:worker_class) { RubyReactor::Adapters::Sidekiq::Worker }

  def run_reactor(reactor_class, inputs = {})
    reactor = reactor_class.new
    [reactor.run(inputs), reactor.context]
  end

  it "re-runs the whole child from a fresh start (S-compose-05)" do
    result, = run_reactor(ComposeRetrySpec::Retried)

    expect(RollbackRecorder.log).to eq(
      %w[run:child.c1 run:child.c2 compensate:child.c2 undo:child.c1 run:child.c1 run:child.c2]
    )
    expect(result).to be_success
    expect(result.value[:child][:c1]).to eq(2)
  end

  it "undoes the final attempt's child steps on a later failure (S-compose-05b)" do
    result, = run_reactor(ComposeRetrySpec::RetriedThenFails)

    expect(RollbackRecorder.log).to eq(
      %w[run:child.c1 run:child.c2 compensate:child.c2 undo:child.c1 run:child.c1 run:child.c2
         run:b compensate:b undo:child.c2 undo:child.c1]
    )
    expect(result.step_name).to eq(:b)
  end

  it "gives the fresh child a fresh retry budget for its own steps" do
    run_reactor(ComposeRetrySpec::RetriedInnerRetries)

    expect(RollbackRecorder.log.count("run:child.c2")).to eq(4)
    expect(RollbackRecorder.log.count("run:child.c1")).to eq(2)
  end

  it "keeps the discarded attempt, and its incomplete rollback, in the parent's trace" do
    _result, context = run_reactor(ComposeRetrySpec::RetriedUndoFails)

    discarded = context.execution_trace.select { |e| e[:type] == :compose_attempt_discarded }
    expect(discarded.size).to eq(1)
    expect(discarded.first[:step]).to eq(:child)
    expect(discarded.first[:child_context_id]).not_to eq(context.composed_contexts[:child][:context].context_id)
    expect(storage.retrieve_context(discarded.first[:child_context_id], "ComposeRetrySpec::ChildUndoFails")["status"])
      .to eq("failed")
    expect(discarded.first[:rollback_failures].map { |f| f[:step] }).to eq([:c1])
  end

  it "re-runs the child when the retry is requeued to a worker" do
    id = ComposeRetrySpec::RetriedInWorker.run({}).execution_id
    RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs

    expect(RollbackRecorder.log).to eq(
      %w[run:child.c1 run:child.c2 compensate:child.c2 undo:child.c1 run:child.c1 run:child.c2]
    )
    expect(ComposeRetrySpec::RetriedInWorker.find(id).context.status.to_s).to eq("completed")
  end

  it "resumes, not retries, a child that parked after c1 completed" do
    key = SecureRandom.hex(4)
    holder = RubyReactor::Lock.new("compose_retry:park:#{key}", owner: "external", ttl: 30, auto_extend: false)
    holder.acquire
    ComposeRetrySpec::ParkingParent.run(key: key)

    worker_class.new.perform(*worker_class.jobs.shift["args"]) # parks at c2
    holder.release
    worker_class.new.perform(*worker_class.jobs.shift["args"]) # resumes

    expect(RollbackRecorder.log).to eq(%w[run:child.c1 run:child.c2])
  ensure
    holder&.release
  end
end
