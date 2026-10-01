require "rails_helper"

RSpec.describe ComposedFanOutDemoReactor, type: :reactor do
  before { described_class.reset! }

  it "resumes the root after the child's fan-out map, and finishes" do
    subject = test_reactor(described_class, {})

    expect(subject).to be_success
    expect(subject).to have_run_step(:notify).after(:fulfil)
    expect(described_class.shipped.size).to eq(5)
  end

  it "rolls back through the root: every shipped item is unshipped" do
    subject = test_reactor(described_class, { fail_notify: true })

    expect(subject).to be_failure
    expect(described_class.unshipped.sort).to eq(described_class.shipped.sort)
    expect(described_class.log(:released)).to eq(["reservation"])
  end
end
