require "rails_helper"

RSpec.describe ComposeRetryDemoReactor, type: :reactor do
  before { described_class.reset! }

  it "re-runs the whole child on the retry, so the seat is reserved on both attempts" do
    subject = test_reactor(described_class, { seat: "12A" })

    expect(subject).to be_success
    expect(subject).to have_retried_step(:reservation).times(1)
    expect(described_class.log).to eq(
      ["reserve 12A", "confirm res_12A_1", "release 12A", "reserve 12A", "confirm res_12A_2"]
    )
    expect(subject.result.value).to eq(confirmed: "res_12A_2")
  end
end
