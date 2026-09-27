# frozen_string_literal: true

require "spec_helper"

# US3-5 (FR-018, 008 R-16): an interruption (a signal, an exit, out of memory,
# an enclosing timeout) runs no rollback code, reaches the caller unchanged, and
# leaves a caller-process run `aborted` for a manual undo.
module AbortedExecutionSpec
  CRASH = Interrupt.new("process going down")

  class Crashes < RollbackRecorder::Reactor
    recording_step :a
    recording_step(:b, after: :a) do
      run do |_inputs, _ctx|
        RollbackRecorder.record("run:b")
        raise CRASH
      end
    end
  end

  class CrashingChild < RollbackRecorder::Reactor
    tag "child"
    input :from_a
    recording_step :c1
    recording_step(:c2, after: :c1) { run { |_inputs, _ctx| raise CRASH } }
  end

  class ComposesCrash < RollbackRecorder::Reactor
    recording_step :a
    compose(:child, CrashingChild) { argument :from_a, result(:a) }
  end

  class Exits < RollbackRecorder::Reactor
    recording_step :a
    recording_step(:b, after: :a) { run { |_inputs, _ctx| raise SystemExit } }
  end

  class Sleeps < RollbackRecorder::Reactor
    recording_step :a
    recording_step(:b, after: :a) { run { |_inputs, _ctx| sleep 2 } }
  end

  # b's undo is interrupted on the first rollback only; c was already undone.
  class InterruptedRollback < RollbackRecorder::Reactor
    recording_step :a
    recording_step(:b, after: :a) do
      undo do |_value, _inputs, _ctx|
        RollbackRecorder.record("undo:b")
        raise CRASH if (RollbackRecorder.counters["b undos"] += 1) == 1

        RubyReactor.Success()
      end
    end
    recording_step :c, after: :b
    recording_step :d, after: :c, fail: true
  end
end

RSpec.describe "a run cut short by an interruption" do
  let(:storage) { RubyReactor.configuration.storage_adapter }
  let(:crash) { AbortedExecutionSpec::CRASH }

  def run_crashing(reactor_class)
    reactor = reactor_class.new
    expect { reactor.run({}) }.to raise_error(Interrupt) { |e| expect(e).to equal(crash) }
    reactor.context.context_id
  end

  def stored(reactor_class, id)
    storage.retrieve_context(id, reactor_class.name)
  end

  it "re-raises the same exception object and runs no rollback (S-edge-03)" do
    run_crashing(AbortedExecutionSpec::Crashes)

    expect(RollbackRecorder.log).to eq(%w[run:a run:b])
  end

  it "records the run as aborted with its undo stack kept" do
    id = run_crashing(AbortedExecutionSpec::Crashes)

    data = stored(AbortedExecutionSpec::Crashes, id)
    expect(data["status"]).to eq("aborted")
    expect(data["undo_stack"]).not_to be_empty
  end

  it "is left alone by the reactor sweeper" do
    run_crashing(AbortedExecutionSpec::Crashes)

    expect(RubyReactor::Sweeper.run_once).to eq(0)
    expect(RubyReactor::Adapters::Sidekiq::Worker.jobs).to be_empty
  end

  it "rolls back on a manual undo" do
    id = run_crashing(AbortedExecutionSpec::Crashes)

    AbortedExecutionSpec::Crashes.undo(id)

    expect(RollbackRecorder.log).to eq(%w[run:a run:b undo:a])
    expect(stored(AbortedExecutionSpec::Crashes, id)["status"]).to eq("cancelled")
  end

  it "marks both a composed child and its root aborted" do
    id = run_crashing(AbortedExecutionSpec::ComposesCrash)

    root = AbortedExecutionSpec::ComposesCrash.find(id).context
    expect(root.status.to_s).to eq("aborted")
    expect(root.composed_contexts[:child][:context].status.to_s).to eq("aborted")
  end

  it "leaves a worker execution running, for redelivery" do
    context = RubyReactor::Context.new({}, AbortedExecutionSpec::Crashes)
    context.inline_async_execution = true

    expect { RubyReactor::Executor.new(AbortedExecutionSpec::Crashes, {}, context).execute }
      .to raise_error(Interrupt)
    expect(stored(AbortedExecutionSpec::Crashes, context.context_id)["status"]).to eq("running")
  end

  it "is never resumed forward by a worker" do
    id = run_crashing(AbortedExecutionSpec::Crashes)
    RollbackRecorder.reset!

    RubyReactor::Adapters::Sidekiq::Worker.new.perform(id, AbortedExecutionSpec::Crashes.name)

    expect(RollbackRecorder.log).to be_empty
    expect(stored(AbortedExecutionSpec::Crashes, id)["status"]).to eq("aborted")
  end

  it "aborts on SystemExit too" do
    reactor = AbortedExecutionSpec::Exits.new
    expect { reactor.run({}) }.to raise_error(SystemExit)

    expect(RollbackRecorder.log).to eq(%w[run:a])
    expect(stored(AbortedExecutionSpec::Exits, reactor.context.context_id)["status"]).to eq("aborted")
  end

  it "lets an enclosing Timeout.timeout fire, and aborts the run" do
    reactor = AbortedExecutionSpec::Sleeps.new
    expect { Timeout.timeout(0.1) { reactor.run({}) } }.to raise_error(Timeout::Error)

    expect(RollbackRecorder.log).to eq(%w[run:a])
    expect(stored(AbortedExecutionSpec::Sleeps, reactor.context.context_id)["status"]).to eq("aborted")
  end

  it "keeps only the entries not yet undone when a rollback is interrupted" do
    id = run_crashing(AbortedExecutionSpec::InterruptedRollback)
    expect(RollbackRecorder.log).to eq(%w[run:a run:b run:c run:d compensate:d undo:c undo:b])

    RollbackRecorder.log.clear
    AbortedExecutionSpec::InterruptedRollback.undo(id)

    expect(RollbackRecorder.log).to eq(%w[undo:b undo:a])
  end
end
