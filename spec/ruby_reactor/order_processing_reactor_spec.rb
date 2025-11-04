require "spec_helper"
require "sidekiq/testing"
RSpec.describe Support::OrderProcessingReactor do
  describe "step validate_order" do
    it "successfully validates order details" do
      result = described_class.new.run(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0)

      expect(result).to be_a(RubyReactor::Success)
      expect(result.value[:validate_order]).to eq({ id: "order_123", amount: 100.0, currency: "USD" })
    end

    it "fails when order_id is missing" do
      result = described_class.new.run(product_id: "prod_456", quantity: 2, amount: 200.0)

      expect(result).to be_a(RubyReactor::Failure)
      expect(result.error).to match("order_id")
    end
  end

  describe "step check_inventory" do
    it "succeeds" do
      reactor = described_class.new
      result = reactor.run(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0)

      expect(result).to be_a(RubyReactor::Success)
      expect(result.value[:check_inventory]).to eq({ product_id: "prod_456", available: true, requested_quantity: 2 })
    end

    it "compensates for check_inventory step" do
      reactor = described_class.new
      result = reactor.run(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0,
                           fail_at: :check_inventory)
      expect(result).to be_a(RubyReactor::Failure)
    end

    it "retries check_inventory step until success_at_retry" do
      reactor = described_class.new
      result = reactor.run(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0,
                           fail_at: :check_inventory, success_at_retry: 3)

      expect(result).to be_a(RubyReactor::Success)
      expect(result.value[:check_inventory]).to eq({ product_id: "prod_456", available: true, requested_quantity: 2 })
    end
  end

  describe "step reserve_inventory" do
    it "succeeds" do
      reactor = described_class.new
      result = reactor.run(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0)

      expect(result).to be_a(RubyReactor::Success)
      expect(result.value[:reserve_inventory]).to eq({ product_id: "prod_456", status: "reserved", quantity: 2 })
    end

    it "compensates for reserve_inventory step" do
      allow_any_instance_of(RubyReactor::Dsl::StepConfig).to receive(:async?).and_return(false) if described_class.respond_to?(:async?)

      reactor = described_class.new
      result = reactor.run(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0,
                           fail_at: :reserve_inventory)
      expect(result).to be_a(RubyReactor::Failure)
    end

    it "retries reserve_inventory step until success_at_retry" do
      allow_any_instance_of(RubyReactor::Dsl::StepConfig).to receive(:async?).and_return(false)
      reactor = described_class.new
      
      result = reactor.run(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0,
                          fail_at: :reserve_inventory, success_at_retry: 2)
      expect(result).to be_a(RubyReactor::Success)
      expect(result.value[:reserve_inventory]).to eq({ product_id: "prod_456", status: "reserved", quantity: 2 })
      expect(reactor.context.retry_context.step_attempts["reserve_inventory"]).to eq(2)
      # result = reactor.run(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0,
      #                     fail_at: :reserve_inventory, success_at_retry: 5)

      # expect(result).to be_a(RubyReactor::Success)
      # expect(result.value[:reserve_inventory]).to eq({ product_id: "prod_456", status: "reserved", quantity: 2 })
      # expect(reactor.context.retry_context.step_attempts["reserve_inventory"]).to eq(5)
    end
  end
  # Additional tests for other steps would go here...
end