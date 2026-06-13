require "rails_helper"

RSpec.describe WebhookInterruptReactor, type: :reactor do
  subject(:reactor) { test_reactor(described_class, { provider_id: "stripe_1" }) }

  it "pauses waiting for the webhook" do
    expect(reactor).to be_paused
    expect(reactor).to be_paused_at(:wait_for_webhook)
  end

  it "completes when the webhook resumes with status approved" do
    reactor.resume(payload: { "status" => "approved" })

    expect(reactor).to be_success
    expect(reactor.result.value).to eq("Request successfully approved via webhook")
  end

  it "fails when the webhook resumes with a rejected status" do
    reactor.resume(payload: { "status" => "rejected" })

    expect(reactor).to be_failure
  end

  it "fails the reactor when the payload fails validate_payload (default max_attempts: 1)" do
    # :status is required by validate_payload. This interrupt uses the default
    # max_attempts of 1, so a single invalid payload exhausts the budget:
    # the reactor compensates and is marked failed rather than staying paused.
    reactor.resume(payload: {})

    expect(reactor).to be_failure
    expect(reactor).not_to be_paused
  end

  context "when initiate_request fails" do
    subject(:reactor) do
      test_reactor(described_class, { provider_id: "x", fail_at: :initiate_request })
    end

    it "fails before ever pausing" do
      expect(reactor).to be_failure
      expect(reactor).not_to be_paused
    end
  end
end
