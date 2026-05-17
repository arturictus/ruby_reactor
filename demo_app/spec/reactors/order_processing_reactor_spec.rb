require "rails_helper"

RSpec.describe OrderProcessingReactor, type: :reactor do
  let(:inputs) do
    { order_id: "order_42", product_id: "prod_1", quantity: 2, amount: 100 }
  end

  subject(:reactor) { test_reactor(described_class, inputs) }

  context "happy path" do
    it "completes through reserve_inventory and process_payment" do
      expect(reactor).to be_success
      expect(reactor).to have_run_step(:validate_order)
      expect(reactor).to have_run_step(:check_inventory).after(:validate_order)
      expect(reactor).to have_run_step(:reserve_inventory).after(:check_inventory)
      expect(reactor).to have_run_step(:process_payment).after(:reserve_inventory)
    end
  end

  context "with input validation failure" do
    let(:inputs) { super().merge(quantity: 0) }

    it "fails with validation error on :quantity" do
      expect(reactor).to be_failure
      expect(reactor).to have_validation_error(:quantity)
    end
  end

  context "when reserve_inventory fails and then succeeds on retry" do
    let(:inputs) { super().merge(fail_at: :reserve_inventory, success_at_retry: 2) }

    it "retries and ultimately succeeds" do
      expect(reactor).to be_success
      expect(reactor).to have_retried_step(:reserve_inventory)
    end
  end

  context "when process_payment fails" do
    let(:inputs) { super().merge(fail_at: :process_payment) }

    it "fails the reactor" do
      expect(reactor).to be_failure
      expect(reactor).to have_run_step(:reserve_inventory)
    end
  end
end
