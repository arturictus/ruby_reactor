require "rails_helper"

RSpec.describe AsyncStepDemoReactor, type: :reactor do
  let(:inputs) { { email: "demo@example.com" } }

  describe "dispatched" do
    subject(:reactor) { test_reactor(described_class, inputs) }

    it "does not block the sibling step that has no dependency on the email" do
      expect(reactor).to have_run_step(:record_signup)
    end

    it "records the dispatch on the parent's own context" do
      expect(reactor.async_step(:send_email)).not_to be_nil
    end
  end

  # `async: false` runs the whole reactor in one process, dispatched units
  # included — the way to exercise a reactor's full logic in a spec without
  # standing up a worker.
  describe "run synchronously" do
    subject(:reactor) { test_reactor(described_class, inputs, async: false) }

    it "completes, with the reader receiving the email step's value" do
      expect(reactor).to be_success
      expect(reactor.result.value).to eq("Confirmed delivery to demo@example.com")
    end

    it "runs every step, including the one that would have been dispatched" do
      expect(reactor).to have_run_step(:send_email)
      expect(reactor).to have_run_step(:confirm_delivery).after(:send_email)
    end
  end
end
