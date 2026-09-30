require "rails_helper"

RSpec.describe MapRefundDemoReactor, type: :reactor do
  let(:orders) do
    [{ id: "o1", amount_cents: 1000 }, { id: "o2", amount_cents: 2000 }, { id: "o3", amount_cents: 3000 }]
  end

  before { described_class.reset! }

  it "refunds the orders already charged when an order's charge fails" do
    subject = test_reactor(described_class, { orders: orders, fail_order_id: "o3" })

    expect(subject).to be_failure
    expect(described_class.charges).to eq(%w[o1 o2])
    expect(described_class.refunds).to eq(%w[o2 o1])
  end

  it "refunds every order when the step after the map fails" do
    subject = test_reactor(described_class, { orders: orders, fail_after_map: true })

    expect(subject).to be_failure
    expect(subject).not_to have_rollback_failure(:charge)
    expect(described_class.charges).to eq(%w[o1 o2 o3])
    expect(described_class.refunds).to eq(%w[o3 o2 o1])
  end

  it "keeps every charge when nothing fails" do
    subject = test_reactor(described_class, { orders: orders })

    expect(subject).to be_success
    expect(subject).to have_run_step(:notify).after(:charge_orders)
    expect(described_class.refunds).to be_empty
  end
end
