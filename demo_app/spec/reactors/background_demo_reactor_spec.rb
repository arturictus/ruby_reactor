require "rails_helper"

RSpec.describe BackgroundDemoReactor, type: :reactor do
  subject(:reactor) { test_reactor(described_class, inputs) }

  context "with a valid user" do
    let(:inputs) { { user_id: 7 } }

    it "completes across the hand-off" do
      expect(reactor).to be_success
      expect(reactor.result.value).to eq("Done")
    end

    it "runs the steps in order, in the calling process and then the worker" do
      expect(reactor).to have_run_step(:validate_user)
      expect(reactor).to have_run_step(:heavy_processing).after(:validate_user)
      expect(reactor).to have_run_step(:notify_completion).after(:heavy_processing)
    end

    it "declares exactly one hand-off point" do
      expect(described_class.background_handoff).to eq({ mode: :after, step: :validate_user })
    end
  end

  context "with a missing user_id" do
    let(:inputs) { { user_id: nil } }

    it "fails in the calling process, before anything is handed off" do
      expect(reactor).to be_failure
      expect(reactor).not_to have_run_step(:heavy_processing)
    end
  end

  context "when forced to run synchronously" do
    subject(:reactor) { test_reactor(described_class, inputs, async: false) }

    let(:inputs) { { user_id: 7 } }

    it "suppresses the hand-off and still completes" do
      expect(reactor).to be_success
      expect(reactor.result.value).to eq("Done")
    end
  end
end
