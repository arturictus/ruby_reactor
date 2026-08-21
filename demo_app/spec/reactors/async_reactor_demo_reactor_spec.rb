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
end
