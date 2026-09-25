require "rails_helper"

RSpec.describe StepRetryDemoReactor, type: :reactor do
  before { StepRetryDemoLog.reset! }

  it "retries :charge under FlakyChargeStep's own policy until it succeeds" do
    subject = test_reactor(described_class, { fail_times: 2 })

    expect(subject).to be_success
    expect(subject).to have_retried_step(:charge).times(2)
  end

  it "exhausts the class policy, then gives the reserved stock back" do
    subject = test_reactor(described_class, { fail_times: 5 })

    expect(subject).to be_failure
    expect(subject).to have_retried_step(:charge).times(2)
    expect(StepRetryDemoLog.compensated).to be(true)
  end

  it "runs :notify, which declares no retries, exactly once" do
    subject = test_reactor(described_class, { fail_times: 0, fail_notify: true })

    expect(subject).to be_failure
    expect(subject).not_to have_retried_step(:notify)
    expect(StepRetryDemoLog.compensated).to be(true)
  end
end
