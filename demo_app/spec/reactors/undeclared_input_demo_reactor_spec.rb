require "rails_helper"

RSpec.describe UndeclaredInputDemoReactor, type: :reactor do
  before { UndeclaredInputDemoLog.reset! }

  it "reads its declared inputs by method" do
    subject = test_reactor(described_class, { order_guid: 42, mode: "ok" })

    expect(subject).to be_success
    expect(subject).to have_run_step(:charge).after(:validate_order)
    expect(subject.step_result(:charge)).to eq(charged: 42)
  end

  it "fails on the typo'd line, names the declared inputs, and never retries" do
    subject = test_reactor(described_class, { order_guid: 42, mode: "typo_in_run" })

    expect(subject).to be_failure
    expect(subject.error.to_s)
      .to include("ValidateOrderGuidStep has no input :order_id. Declared inputs: :order_guid, :mode.")
    expect(subject.result.exception_class).to eq("RubyReactor::Error::UndeclaredInputError")
    expect(subject).not_to have_retried_step(:validate_order)
    expect(UndeclaredInputDemoLog.validate_attempts).to eq(1)
    expect(UndeclaredInputDemoLog.released).to be(true)
  end

  it "reports a typo in compensate as a rollback failure, and still rolls back the rest" do
    subject = test_reactor(described_class, { order_guid: 42, mode: "typo_in_compensate" })

    expect(subject).to be_failure
    expect(subject).to have_rollback_failure(:charge)
    expect(UndeclaredInputDemoLog.released).to be(true)
  end
end
