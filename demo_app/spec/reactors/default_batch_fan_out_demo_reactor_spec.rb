require "rails_helper"

RSpec.describe DefaultBatchFanOutDemoReactor, type: :reactor do
  it "fans out all 120 elements without a declared batch_size" do
    subject = test_reactor(described_class, {})

    expect(subject).to be_success
    expect(subject.step_result(:doubled)).to eq(120)
  end
end
