require "rails_helper"

RSpec.describe StepLockRollbackDemoReactor, type: :reactor do
  describe "rollback under contention" do
    it "waits for a key held past the failure and runs the undo once it is free" do
      account_id = "acct_#{SecureRandom.hex(4)}"

      subject = test_reactor(described_class, { account_id: account_id, rollback_hold_seconds: 0.3 })

      expect(subject).to be_failure
      expect(subject).not_to have_rollback_failure(:charge)
      expect(StepLockRollbackChargeStep.undone).to include(account_id)
    end

    it "reports the undo on the failure when the key stays busy past rollback_wait" do
      account_id = "acct_#{SecureRandom.hex(4)}"

      subject = test_reactor(described_class, { account_id: account_id, rollback_hold_seconds: 2.0 })

      expect(subject).to be_failure
      expect(subject).to have_rollback_failure(:charge)
        .for_key("demo:acct:#{account_id}")
        .because(:coordination_unavailable)
      expect(StepLockRollbackChargeStep.undone).not_to include(account_id)
    end
  end
end
