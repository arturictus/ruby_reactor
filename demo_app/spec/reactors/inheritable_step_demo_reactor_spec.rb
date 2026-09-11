require "rails_helper"

RSpec.describe InheritableStepDemoReactor, type: :reactor do
  before { ChargeStep.instance_variable_set(:@refunds, []) }

  let(:inputs) { { user_id: 7 } }

  subject(:reactor) { test_reactor(described_class, inputs) }

  it "charges through the wrapped legacy service" do
    expect(reactor).to be_success
    expect(reactor).to have_run_step(:charge)
    expect(reactor.result.value).to eq(charge_id: 42)
  end

  context "when a later step forces a failure" do
    let(:inputs) { super().merge(fail: true) }

    it "fails and rolls back the charge via ChargeStep#undo" do
      expect(reactor).to be_failure
      expect(ChargeStep.refunds).to eq([42])
    end
  end

  context "with an invalid user_id" do
    let(:inputs) { { user_id: 0 } }

    it "rejects before the legacy service is ever instantiated, non-retryably" do
      expect(reactor).to be_failure
      expect(reactor).to have_validation_error(:user_id)
      expect(reactor.result.retryable?).to be(false)
    end
  end
end
