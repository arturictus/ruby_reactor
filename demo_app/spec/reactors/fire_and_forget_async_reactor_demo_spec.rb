require "rails_helper"

RSpec.describe FireAndForgetAsyncReactorDemo, type: :reactor do
  describe "dispatched" do
    let(:inputs) { { user_id: 10 } }
    subject(:reactor) { test_reactor(described_class, inputs) }

    it "succeeds immediately, without any reader on the dispatched child" do
      expect(reactor).to be_success
      expect(reactor.async_reactor(:backfill_profile)).not_to be_nil
    end
  end

  describe "when the never-awaited child fails" do
    let(:inputs) { { user_id: 11, fail_at: :backfill } }
    subject(:reactor) { test_reactor(described_class, inputs, async: false) }

    it "still succeeds — nobody ever reads the child's result" do
      expect(reactor).to be_success
      expect(reactor.async_reactor(:backfill_profile)).to be_failure
    end
  end
end
