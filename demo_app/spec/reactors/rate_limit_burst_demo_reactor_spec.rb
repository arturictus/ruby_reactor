# frozen_string_literal: true

require "rails_helper"

RSpec.describe RateLimitBurstDemoReactor, type: :reactor do
  subject(:reactor) { test_reactor(described_class, { account_id: "acct_1" }) }

  it "allows three calls and reports the fourth as exceeded" do
    expect(reactor).to be_success

    attempts = reactor.result.value[:attempts]
    expect(attempts.size).to eq(4)
    expect(attempts[0..2].map { |a| a[:status] }).to all(eq(:allowed))
    expect(attempts[3][:status]).to eq(:exceeded)
    expect(attempts[3][:period]).to eq("second")
  end

  it "records three calls in the rate limit window" do
    expect(reactor).to be_success
    expect("api:acct_1").to have_rate_limit_count(3).for(:second)
  end
end
