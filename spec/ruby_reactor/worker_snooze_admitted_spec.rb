# frozen_string_literal: true

require "spec_helper"

# 010 R-07 / J-8: snooze escalation marks a run `failed` without rolling back,
# so it applies only before admission. An admitted run (here, a resume
# deferred on the reactor's lock) keeps waiting and warns once.
module WorkerSnoozeAdmittedSpec
  class FirstRunLocked < RubyReactor::Reactor
    background all: true
    with_lock { |_inputs| "snooze-spec:first" }

    step :x do
      run { |_inputs, _ctx| RubyReactor.Success(:x) }
    end
  end
end

RSpec.describe "Worker snooze limit after admission (010 R-07)" do
  let(:logger) { RubyReactor.configuration.logger }

  before do
    RubyReactor.configuration.lock_snooze_max_attempts = 2 # spec_helper resets it to 20
    Sidekiq::Worker.clear_all
    allow(logger).to receive(:warn).and_call_original
  end

  def hold(key)
    lock = RubyReactor::Lock.new(key, owner: "another-run", ttl: 30, auto_extend: false)
    lock.acquire
    lock
  end

  def perform_next
    QueueProbe.next_job.perform!
  end

  it "keeps a deferred resume waiting past the limit, warning once" do
    klass = ResumeFixtures::LockedApproval
    reactor = klass.new
    reactor.run({})
    id = reactor.context.context_id
    held = hold("resume-fx:locked")

    expect(klass.continue(id: id, payload: { ok: true }, step_name: :approval)).to be_a(RubyReactor::DispatchResult)
    4.times { perform_next }

    expect(klass.find(id).context.status.to_s).to eq("running")
    expect(logger).to have_received(:warn).with(/event="ruby_reactor.resume.waiting".*snooze_count=2/).once

    held.release
    RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs
    expect(klass.find(id).context.status.to_s).to eq("completed")
  ensure
    held&.release
  end

  it "still escalates a first run that never got past the lock, as before" do
    held = hold("snooze-spec:first")
    result = WorkerSnoozeAdmittedSpec::FirstRunLocked.run({})
    id = result.execution_id

    3.times { perform_next }

    expect(WorkerSnoozeAdmittedSpec::FirstRunLocked.find(id).context.status.to_s).to eq("failed")
    expect(logger).not_to have_received(:warn).with(/ruby_reactor.resume.waiting/)
  ensure
    held&.release
  end
end
