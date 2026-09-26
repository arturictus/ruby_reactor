require "rails_helper"

RSpec.describe AsyncStepCompensateDemoReactor, type: :reactor do
  before { described_class.reset! }

  it "compensates the unit once, in its own job, after its last attempt" do
    subject = test_reactor(described_class, { user_id: "u1" })
    expect(subject).to be_success

    drain_async_jobs

    expect(subject.async_step(:notify, :attempts)).to eq(2)
    expect(subject.async_step(:notify, :compensation)["status"]).to eq("completed")
    expect(described_class.log).to eq(
      ["notify u1", "notify u1", "compensate notify u1: push gateway unavailable"]
    )
  end
end
