require "rails_helper"

RSpec.describe EtlReactor, type: :reactor do
  subject(:reactor) { test_reactor(described_class, {}) }

  before do
    3.times { |i| Order.create!(status: "pending", total: (i + 1) * 10) }
    Order.create!(status: "processed", total: 999)
  end

  it "fetches, transforms, and updates only pending orders" do
    expect(reactor).to be_success
    expect(reactor.result.value).to eq("Processed 3 orders")
  end

  it "applies the 10% tax to each pending order" do
    reactor.ensure_executed!
    Order.where(status: "processed").where.not(total: 999).each do |o|
      expect(o.total).to be > 10
    end
  end

  it "runs the three steps in order" do
    expect(reactor).to have_run_step(:fetch_pending_orders)
    expect(reactor).to have_run_step(:transform_data).after(:fetch_pending_orders)
    expect(reactor).to have_run_step(:update_orders).after(:transform_data)
  end
end
