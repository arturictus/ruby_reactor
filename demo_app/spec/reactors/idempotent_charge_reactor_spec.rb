# frozen_string_literal: true

require "rails_helper"

# 011 US6: one charge per idempotency key, on both storage adapters.
RSpec.describe IdempotentChargeReactor, type: :reactor do
  before { described_class::Ledger.reset! }

  let(:order_id) { "ord_#{SecureRandom.hex(3)}" }
  let(:key) { "charge-order-#{order_id}" }

  it "charges once, and replays the result for a repeated request" do
    first = test_reactor(described_class, { order_id: order_id, amount: 100 }, idempotency_key: key)
    expect(first).to be_success
    expect(first).to have_run_step(:charge)

    again = test_reactor(described_class, { order_id: order_id, amount: 100 }, idempotency_key: key)
    expect(again).to be_idempotent_replay
    expect(again).to be_success
    expect(again.reactor_instance.context.context_id).to eq(first.reactor_instance.context.context_id)
    expect(described_class::Ledger.entries).to eq([[:reserved, order_id, 100], [:charged, order_id, 100]])
  end

  it "releases the reservation when the card is declined, and replays that failure" do
    first = test_reactor(described_class, { order_id: order_id, amount: 50, decline: true }, idempotency_key: key)
    expect(first).to be_failure
    expect(described_class::Ledger.entries).to include([:released, order_id, 50])

    again = test_reactor(described_class, { order_id: order_id, amount: 50 }, idempotency_key: key)
    expect(again).to be_idempotent_replay
    expect(again).to be_failure
    expect(described_class::Ledger.entries.count { |entry| entry.first == :reserved }).to eq(1)
  end
end
