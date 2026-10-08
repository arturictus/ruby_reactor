# frozen_string_literal: true

require "spec_helper"

# 010 R-09: `Reactor#undo` reloads the run after taking its lock, so an undo
# built from an older snapshot never undoes (and saves) stale state.
module UndoReloadSpec
  class TwoPauses < RollbackRecorder::Reactor
    recording_step :a
    interrupt(:first) { wait_for :a }
    recording_step :b, after: :first
    interrupt(:second) { wait_for :b }
    recording_step :c, after: :second
  end
end

RSpec.describe "Reactor#undo reloads under its lock (010 R-09)" do
  let(:klass) { UndoReloadSpec::TwoPauses }

  # A snapshot taken at the first pause, then the run moves on to the second.
  def stale_snapshot
    reactor = klass.new
    expect(reactor.run({})).to be_a(RubyReactor::InterruptResult)
    id = reactor.context.context_id
    stale = klass.find(id)
    klass.continue(id: id, payload: { ok: true }, step_name: :first)
    expect(klass.find(id).context.status.to_s).to eq("paused")
    [id, stale]
  end

  it "undoes the steps the newer save recorded, not the snapshot's" do
    id, stale = stale_snapshot

    stale.undo

    expect(RollbackRecorder.log).to eq(%w[run:a run:b undo:b undo:a])
    expect(klass.find(id).context.undo_stack).to be_empty
  end

  it "ends the run failed with the given reason when called with failure:" do
    id, stale = stale_snapshot

    stale.undo(failure: { message: "too many attempts", step_name: :second })

    context = klass.find(id).context
    expect(context.status.to_s).to eq("failed")
    expect(RubyReactor::Utils::FetchIndifferent.call(context.failure_reason, :message)).to eq("too many attempts")
    expect(RollbackRecorder.log).to eq(%w[run:a run:b undo:b undo:a])
  end
end
