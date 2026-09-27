require "rails_helper"

RSpec.describe ComposeRetryDemoReactor, type: :reactor do
  before { described_class.reset! }

  it "retries the flaky step inside the child and reserves the seat once" do
    subject = test_reactor(described_class, { seat: "12A" })

    expect(subject).to be_success
    expect(described_class.confirm_calls).to eq(2)
    expect(described_class.log).to eq(["reserve 12A", "confirm res_12A_1", "confirm res_12A_1"])
    expect(subject.result.value).to eq(confirmed: "res_12A_1")
  end
end
