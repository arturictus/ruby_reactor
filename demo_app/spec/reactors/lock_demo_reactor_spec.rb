# frozen_string_literal: true

require "rails_helper"

RSpec.describe LockDemoReactor, type: :reactor do
  let(:inputs) { { order_id: "order_42", hold_seconds: 0 } }

  subject(:reactor) { test_reactor(described_class, inputs, async: false) }

  context "happy path" do
    it "completes through all steps including re-entrant compose" do
      expect(reactor).to be_success
      expect(reactor).to have_run_step(:prepare_refund)
      expect(reactor).to have_run_step(:verify_ledger).after(:prepare_refund)
      expect(reactor).to have_run_step(:process_refund).after(:verify_ledger)
      expect(reactor).to have_run_step(:finalize_refund).after(:process_refund)
    end

    it "releases the lock after a successful run" do
      expect(reactor).to be_success
      expect("order:order_42").not_to be_locked
    end
  end

  context "while processing" do
    it "holds the lock for the duration of the long step" do
      thread = Thread.new do
        test_reactor(described_class, { order_id: "order_42", hold_seconds: 1 }, async: false).result
      end
      sleep 0.1

      expect("order:order_42").to be_locked

      thread.join
      expect("order:order_42").not_to be_locked
    end
  end

  context "when lock is held by another owner" do
    before do
      redis.hset("lock:order:order_42", "owner", "other_process")
      redis.hset("lock:order:order_42", "count", "1")
    end

    it "raises Lock::AcquisitionError on inline execution" do
      expect do
        test_reactor(described_class, { order_id: "order_42", hold_seconds: 0 }, async: false).result
      end.to raise_error(RubyReactor::Lock::AcquisitionError)
    end
  end
end
