require "rails_helper"

RSpec.describe ArgumentFailureDemoReactor, type: :reactor do
  before { described_class.reset! }

  it "releases the reservation and names :charge when its argument transform raises" do
    subject = test_reactor(described_class, { sku: "sku-1", price: "abc" })

    expect(subject).to be_failure
    expect(subject.result.step_name.to_s).to eq("charge")
    expect(subject.result.exception_class).to eq("ArgumentError")
    expect(described_class.log).to eq(["reserve sku-1", "release sku-1"])
  end

  it "charges when the price parses" do
    subject = test_reactor(described_class, { sku: "sku-1", price: "12.50" })

    expect(subject).to be_success
    expect(subject).to have_run_step(:charge).after(:reserve)
    expect(described_class.log).to eq(["reserve sku-1", "charge 1250"])
  end
end
