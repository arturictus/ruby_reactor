# frozen_string_literal: true

RSpec.describe RubyReactor::PaymentWorkflow do
  describe "get order step" do
    it "successfully retrieves order details" do
      result = described_class.new.run(order_id: "order_123")

      expect(result).to be_a(RubyReactor::Success)
      expect(result.value[:get_order]).to eq({ id: "order_123", amount: 100.0, currency: "USD" })
    end

    it "compensates for get_order step" do
      reactor = described_class.new
      result = reactor.run(order_id: "order_123", fail_at: :get_order)

      expect(result).to be_a(RubyReactor::Failure)
    end

    it "fails when order_id is missing" do
      result = described_class.new.run({})

      expect(result).to be_a(RubyReactor::Failure)
      expect(result.error.message).to match("order_id")
    end
  end

  describe "step reserve_inventory" do
    it "succeeds" do
      reactor = described_class.new
      result = reactor.run(order_id: "order_123")

      expect(result).to be_a(RubyReactor::Success)
      expect(result.value[:reserve_inventory]).to eq({ id: "order_123", status: "pending", inventory_count: 5,
                                                       reserved: true })
    end

    it "compensates for reserve_inventory step" do
      reactor = described_class.new
      result = reactor.run(order_id: "order_123", fail_at: :reserve_inventory)
      expect(result).to be_a(RubyReactor::Failure)
    end
  end

  describe "step authorize_payment" do
    it "succeeds" do
      reactor = described_class.new
      result = reactor.run(order_id: "order_123")
      expect(result).to be_a(RubyReactor::Success)
      expect(result.value[:authorize_payment]).to eq({ id: "order_123", status: "authorized", amount: 100.0 })
    end

    it "compensates for authorize_payment step" do
      reactor = described_class.new
      result = reactor.run(order_id: "order_123", fail_at: :authorize_payment)
      expect(result).to be_a(RubyReactor::Failure)
    end
  end

  describe "step capture_payment" do
    it "succeeds" do
      reactor = described_class.new
      result = reactor.run(order_id: "order_123")
      expect(result).to be_a(RubyReactor::Success)
      expect(result.value[:capture_payment]).to eq({ id: "order_123", status: "captured", amount: 100.0 })
    end

    it "fails when capture_payment step raises an error" do
      reactor = described_class.new
      result = reactor.run(order_id: "order_123", fail_at: :capture_payment)
      expect(result).to be_a(RubyReactor::Failure)
      expect(reactor.undo_trace[0][:step]).to eq(:capture_payment)
      expect(reactor.undo_trace[0][:type]).to eq(:compensation)
      expect(reactor.undo_trace[1][:step]).to eq(:authorize_payment)
    end
  end

  describe "step fullfill_order" do
    it "succeeds" do
      reactor = described_class.new
      result = reactor.run(order_id: "order_123")
      expect(result).to be_a(RubyReactor::Success)
      expect(result.value[:fulfill_order]).to eq({ id: "fulfill_order", status: "done" })
    end

    it "run compensation for fulfill_order when fulfill_order step fails" do
      reactor = described_class.new
      result = reactor.run(order_id: "order_123", fail_at: :fulfill_order)
      expect(result).to be_a(RubyReactor::Failure)
      expect(reactor.undo_trace[0][:step]).to eq(:fulfill_order)
    end
  end
end
