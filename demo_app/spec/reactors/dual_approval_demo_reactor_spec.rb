require "rails_helper"

RSpec.describe DualApprovalDemoReactor, type: :reactor do
  subject(:reactor) { test_reactor(described_class, { request_id: 7 }, process_jobs: false) }

  it "waits for both approvals" do
    expect(reactor).to have_ready_interrupts(:finance, :legal)
  end

  it "accepts :legal while :finance's background resume is pending, and applies both once" do
    reactor.run

    reactor.resume(step: :finance, payload: { approved: true }, process_jobs: false)
    expect(reactor).to be_resume_deferred

    reactor.resume(step: :legal, payload: { approved: true }, process_jobs: false)
    expect(reactor).to be_resume_deferred

    drain_async_jobs
    expect(reactor).to be_success
    expect(reactor.step_result(:approve_all)).to eq(finance: true, legal: true)
  end
end
