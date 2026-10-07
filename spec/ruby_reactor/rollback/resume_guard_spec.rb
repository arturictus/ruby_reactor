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

  class LockedApproval < RollbackRecorder::Reactor
    with_lock { |_inputs| "resume-guard:locked" }
    recording_step :a
    interrupt(:approval) { wait_for :a }
    recording_step :c, after: :approval
  end

  class SemaphoredApproval < RollbackRecorder::Reactor
    with_semaphore(limit: 1) { |_inputs| "resume-guard:semaphore" }
    recording_step :a
    interrupt(:approval) { wait_for :a }
    recording_step :c, after: :approval
  end
end

RSpec.describe "resuming a reactor that is not paused (FR-032)", type: :reactor do
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

  # Contention on the resume is the caller's to retry (locks_and_semaphores.md,
  # "Inline vs background behavior on contention"): the run stays paused.
  {
    "reactor lock" => [ResumeGuardSpec::LockedApproval, RubyReactor::Lock::AcquisitionError,
                       -> { RubyReactor::Lock.new("resume-guard:locked", owner: "another-run", auto_extend: false) }],
    "reactor semaphore" => [ResumeGuardSpec::SemaphoredApproval, RubyReactor::Semaphore::AcquisitionError,
                            -> { RubyReactor::Semaphore.new("resume-guard:semaphore", limit: 1) }]
  }.each do |primitive, (reactor_class, contention_error, holder)|
    it "leaves the run paused when its resume is contended on the #{primitive}, so it can be retried" do
      id = pause(reactor_class)
      held = holder.call
      held.acquire

      expect { reactor_class.continue(id: id, payload: { ok: true }, step_name: :approval) }
        .to raise_error(contention_error)
      expect(reactor_class.find(id).context.status.to_s).to eq("paused")

      held.release
      expect(reactor_class.continue(id: id, payload: { ok: true }, step_name: :approval)).to be_success
      expect(RollbackRecorder.log).to eq(%w[run:a run:c])
    end
  end
end
