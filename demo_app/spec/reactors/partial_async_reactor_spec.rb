require "rails_helper"

RSpec.describe PartialAsyncReactor, type: :reactor do
  subject(:reactor) { test_reactor(described_class, inputs) }

  context "with a valid user" do
    let(:inputs) { { user_id: 7 } }

    it "runs sync validation, async heavy work, then sync notify" do
      expect(reactor).to be_success
      expect(reactor.result.value).to eq("Done")
    end

    it "executes the steps in order" do
      expect(reactor).to have_run_step(:validate_user)
      expect(reactor).to have_run_step(:heavy_processing).after(:validate_user)
      expect(reactor).to have_run_step(:notify_completion).after(:heavy_processing)
    end
  end

  context "with a missing user_id" do
    let(:inputs) { { user_id: nil } }

    it "fails at validate_user" do
      expect(reactor).to be_failure
      expect(reactor).not_to have_run_step(:heavy_processing)
    end
  end
end
