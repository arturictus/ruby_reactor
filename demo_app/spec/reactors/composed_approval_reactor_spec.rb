require "rails_helper"

RSpec.describe ComposedApprovalReactor, type: :reactor do
  subject(:reactor) { test_reactor(described_class, { order_id: 1 }) }

  let(:path) { described_class::APPROVAL }

  it "pauses the root at the interrupt inside the composed child" do
    expect(reactor).to be_paused_at(path)
    expect(reactor).to have_ready_interrupts(path)
  end

  it "finishes the root once the manager approves" do
    reactor.resume(step: path, payload: { approved: true })

    expect(reactor).to be_success
    expect(reactor).to have_run_step(:ship).after(:approval)
  end

  it "fails the root when the manager rejects" do
    reactor.resume(step: path, payload: { approved: false })

    expect(reactor).to be_failure
  end

  it "rolls the whole run back on an invalid decision (max_attempts 1, the default)" do
    reactor.resume(step: path, payload: {})

    expect(reactor).to be_failure
  end
end
