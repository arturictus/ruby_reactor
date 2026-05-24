# frozen_string_literal: true

require "rails_helper"

RSpec.describe LockInlineContentionDemoReactor, type: :reactor do
  subject(:reactor) { test_reactor(described_class, { order_id: "contention_order" }) }

  it "demonstrates inline lock contention" do
    expect(reactor).to be_success
    expect(reactor.result.value[:inline_contention]).to be true
    expect(reactor.result.value[:lock_key]).to eq("order:contention_order")
    expect(reactor).to have_run_step(:demonstrate_inline_contention)
  end

  it "does not leave the lock held after the demonstration" do
    expect(reactor).to be_success
    expect("order:contention_order").not_to be_locked
  end
end
