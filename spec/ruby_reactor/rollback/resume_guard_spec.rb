# frozen_string_literal: true

require "spec_helper"

# FR-032: a resume is accepted only by a reactor paused at an interrupt. One
# that arrives while the reactor executes or rolls back fails and changes nothing.
module ResumeGuardSpec
  def self.attempts
    @attempts ||= []
  end

  # Resume the reactor from inside its own rollback: it is compensating.
  class CompensatingResume < RollbackRecorder::Reactor
    recording_step :a do
      undo do |_value, _inputs, ctx|
        RollbackRecorder.record("undo:a")
        CompensatingResume.continue(id: ctx.context_id, payload: { ok: true }, step_name: :approval)
        ResumeGuardSpec.attempts << :accepted
      rescue RubyReactor::Error::ValidationError => e
        ResumeGuardSpec.attempts << e.message
      end
    end
    interrupt(:approval) { wait_for :a }
    recording_step :c, after: :approval, fail: true
  end

  class InterruptedAfterResume < RollbackRecorder::Reactor
    recording_step :a
    interrupt(:approval) { wait_for :a }
    recording_step(:c, after: :approval) { run { |_inputs, _ctx| raise Interrupt } }
  end
end

RSpec.describe "resuming a reactor that is not paused (FR-032)" do
  before { ResumeGuardSpec.attempts.clear }

  def pause(reactor_class)
    reactor = reactor_class.new
    expect(reactor.run({})).to be_a(RubyReactor::InterruptResult)
    reactor.context.context_id
  end

  it "fails a resume that arrives while the reactor is compensating" do
    id = pause(ResumeGuardSpec::CompensatingResume)

    result = ResumeGuardSpec::CompensatingResume.continue(id: id, payload: { ok: true }, step_name: :approval)

    expect(result).to be_failure
    expect(ResumeGuardSpec.attempts).to contain_exactly(/Cannot resume.*running.*not paused/)
    expect(RollbackRecorder.log).to eq(%w[run:a run:c compensate:c undo:a])
  end

  it "fails a resume of an aborted run" do
    id = pause(ResumeGuardSpec::InterruptedAfterResume)
    expect do
      ResumeGuardSpec::InterruptedAfterResume.continue(id: id, payload: { ok: true }, step_name: :approval)
    end.to raise_error(Interrupt)

    expect do
      ResumeGuardSpec::InterruptedAfterResume.continue(id: id, payload: { ok: true }, step_name: :approval)
    end.to raise_error(RubyReactor::Error::ValidationError, /aborted.*not paused/)
  end
end
