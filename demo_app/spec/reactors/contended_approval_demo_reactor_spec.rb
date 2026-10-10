require "rails_helper"

RSpec.describe ContendedApprovalDemoReactor, type: :reactor do
  subject(:reactor) { test_reactor(described_class, { request_id: 1 }, process_jobs: false) }

  it "pauses at :approve" do
    expect(reactor).to be_paused_at(:approve)
  end

  it "accepts a resume while another run holds the lock, and finishes it once the lock is free" do
    reactor.run

    hold_lock("demo:approval:1", owner: "another-run") do
      reactor.resume(payload: { approved: true }, process_jobs: false)
    end

    expect(reactor).to be_resume_deferred
    drain_async_jobs
    expect(reactor).to be_success
    expect(reactor.step_result(:record)).to eq(approved: true)
  end

  it "still answers an invalid payload with its validation failure, leaving the run paused" do
    reactor.run

    hold_lock("demo:approval:1", owner: "another-run") do
      reactor.resume(payload: { approved: "maybe" }, process_jobs: false)
    end

    expect(reactor).not_to be_resume_deferred
    expect(reactor).to be_paused_at(:approve)
  end
end
