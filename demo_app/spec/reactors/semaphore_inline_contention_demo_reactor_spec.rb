# frozen_string_literal: true

require "rails_helper"

RSpec.describe SemaphoreInlineContentionDemoReactor, type: :reactor do
  subject(:reactor) { test_reactor(described_class, { request_id: "req_blocked" }) }

  it "demonstrates inline semaphore exhaustion" do
    expect(reactor).to be_success
    expect(reactor.result.value[:inline_contention]).to be true
    expect(reactor.result.value[:semaphore_key]).to eq("payment_gateway")
    expect(reactor).to have_run_step(:demonstrate_inline_exhaustion)
  end

  it "returns all tokens to the pool after the demonstration" do
    expect(reactor).to be_success
    expect("payment_gateway").to have_available_tokens(2)
    expect("payment_gateway").to have_held_tokens(0)
  end
end
