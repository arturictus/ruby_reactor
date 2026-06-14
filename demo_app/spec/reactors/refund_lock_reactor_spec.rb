require "rails_helper"

RSpec.describe RefundLockReactor, type: :reactor do
  before { described_class::Log.reset! }

  describe "happy path" do
    it "issues a refund and releases the lock" do
      result = test_reactor(described_class, { order_id: "ord_1", amount: 99 })
      expect(result).to be_success
      expect("refund:ord_1").not_to be_locked
      expect(described_class::Log.entries.map { |e| e[:order_id] }).to include("ord_1")
    end
  end

  describe "concurrent submissions" do
    it "serializes refunds for the same order across the worker pool" do
      RubyReactor.configuration.lock_snooze_base_delay = 0.01
      RubyReactor.configuration.lock_snooze_jitter = 0

      3.times do
        test_reactor(described_class, { order_id: "ord_2", amount: 10 }, process_jobs: false).run
      end
      drain_async_jobs

      entries = described_class::Log.entries.select { |e| e[:order_id] == "ord_2" }
      expect(entries.size).to eq(3)
    end

    it "runs refunds for different orders independently" do
      test_reactor(described_class, { order_id: "ord_a", amount: 1 }, process_jobs: false).run
      test_reactor(described_class, { order_id: "ord_b", amount: 2 }, process_jobs: false).run
      drain_async_jobs

      order_ids = described_class::Log.entries.map { |e| e[:order_id] }
      expect(order_ids).to contain_exactly("ord_a", "ord_b")
    end
  end

  describe "contention" do
    it "snoozes the worker when another holder owns the lock" do
      RubyReactor.configuration.storage_adapter
                 .lock_acquire("lock:refund:ord_3", "other-owner", 30)

      RubyReactor.configuration.lock_snooze_base_delay = 0.01
      RubyReactor.configuration.lock_snooze_jitter = 0
      RubyReactor.configuration.lock_snooze_max_attempts = 2

      expect(test_reactor(described_class, { order_id: "ord_3", amount: 1 })).to be_failure
      expect(described_class::Log.entries.map { |e| e[:order_id] }).not_to include("ord_3")
    end
  end
end
