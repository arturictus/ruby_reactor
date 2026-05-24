# frozen_string_literal: true

require "rails_helper"

RSpec.describe SemaphoreDemoReactor, type: :reactor do
  let(:inputs) { { request_id: "req_1", hold_seconds: 0 } }

  subject(:reactor) { test_reactor(described_class, inputs) }

  context "with full-async execution (default)" do
    it "completes successfully through all steps" do
      expect(reactor).to be_success
      expect(reactor).to have_run_step(:validate_request)
      expect(reactor).to have_run_step(:call_payment_gateway).after(:validate_request)
      expect(reactor).to have_run_step(:record_transaction).after(:call_payment_gateway)
    end

    it "returns tokens to the pool after sequential runs" do
      3.times do |i|
        expect(
          test_reactor(described_class, { request_id: "req_#{i}", hold_seconds: 0 }).result
        ).to be_success
      end

      expect("payment_gateway").to have_available_tokens(2)
      expect("payment_gateway").to have_held_tokens(0)
    end
  end

  context "when forced to run synchronously" do
    subject(:reactor) { test_reactor(described_class, inputs, async: false) }

    it "completes successfully through all steps" do
      expect(reactor).to be_success
      expect(reactor).to have_run_step(:validate_request)
      expect(reactor).to have_run_step(:call_payment_gateway).after(:validate_request)
      expect(reactor).to have_run_step(:record_transaction).after(:call_payment_gateway)
    end

    context "when semaphore capacity is exhausted" do
      before do
        2.times.map { RubyReactor::Semaphore.new("payment_gateway", limit: 2) }.each(&:acquire)
      end

      it "raises Semaphore::AcquisitionError on inline execution" do
        expect do
          test_reactor(described_class, { request_id: "req_blocked", hold_seconds: 0 }, async: false).result
        end.to raise_error(RubyReactor::Semaphore::AcquisitionError)
      end
    end
  end
end
