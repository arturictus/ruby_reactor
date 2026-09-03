require "rails_helper"

RSpec.describe AsyncReactorDemoReactor, type: :reactor do
  let(:inputs) { { user_id: 7 } }

  describe "dispatched" do
    subject(:reactor) { test_reactor(described_class, inputs) }

    it "links each child execution to the parent's context" do
      expect(reactor.async_reactor(:backfill_profile)).not_to be_nil
    end

    it "keeps the fire-and-forget child out of the parent's compensation graph" do
      config = described_class.steps[:backfill_profile]

      expect(config.compensate_block).to be_nil
      expect(config.undo_block).to be_nil
    end
  end

  describe "run synchronously" do
    subject(:reactor) { test_reactor(described_class, inputs, async: false) }

    it "completes, with the awaited child's real outcome reaching :verify" do
      expect(reactor).to be_success
      expect(reactor.result.value).to eq("Provisioned acct-7")
    end

    it "still runs the fire-and-forget child" do
      child = reactor.async_reactor(:backfill_profile)

      expect(child).to be_success
    end
  end

  describe "when the fire-and-forget child fails" do
    let(:inputs) { { user_id: 8, fail_at: :backfill } }
    subject(:reactor) { test_reactor(described_class, inputs, async: false) }

    it "still succeeds — nothing reads the failing child's result" do
      expect(reactor).to be_success
      expect(reactor.async_reactor(:backfill_profile)).to be_failure
    end
  end

  describe "when the awaited child fails" do
    let(:inputs) { { user_id: 9, fail_at: :provision } }
    subject(:reactor) { test_reactor(described_class, inputs, async: false) }

    it "fails the reactor with the child's error" do
      expect(reactor).to be_failure
      expect(reactor.result.error).to include("Provisioning service declined the request")
    end

    it "compensates :reserve_seat, which already ran" do
      allow(Rails.logger).to receive(:warn).and_call_original

      expect(reactor).to be_failure
      expect(Rails.logger).to have_received(:warn).with(/releasing provisioning seat/)
    end
  end
end
