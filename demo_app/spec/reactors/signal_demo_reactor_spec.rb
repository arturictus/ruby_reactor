# frozen_string_literal: true

require "rails_helper"

RSpec.describe SignalDemoReactor, type: :reactor do
  let(:inputs) { { order_id: "order_1" } }

  subject(:reactor) { test_reactor(described_class, inputs) }

  context "happy path" do
    it "runs every step to success" do
      expect(reactor).to be_success
      expect(reactor).to have_run_step(:gate)
      expect(reactor).to have_run_step(:charge).after(:gate)
      expect(reactor).to have_run_step(:notify).after(:charge)
      expect(reactor).to have_run_step(:finalize).after(:notify)
    end
  end

  context "halt! at :gate" do
    let(:inputs) { { order_id: "order_1", halt_at: :gate } }

    it "halts cleanly with the reason and halting step, running nothing else" do
      expect(reactor).to be_halted.because("gate closed").at_step(:gate)
      expect(reactor.reactor_instance.context.execution_trace.map { |e| e[:step] }).not_to include(:charge)
    end
  end

  context "skip! at :notify" do
    let(:inputs) { { order_id: "order_1", skip_notify: true } }

    it "continues the workflow and hands :charge's value through unchanged" do
      expect(reactor).to be_success
      expect(reactor).to be_skipped.at_step(:notify)
      expect(reactor.result.value).to eq(charged: true, order_id: "order_1")
    end
  end

  context "skip! at the result-returning step" do
    let(:inputs) { { order_id: "order_1", skip_finalize: true } }

    it "completes and returns the skipped value as the workflow result" do
      expect(reactor).to be_success
      expect(reactor).to be_skipped.at_step(:finalize)
      expect(reactor.result.value).to eq(notified: true, charge: { charged: true, order_id: "order_1" })
    end
  end

  context "fail! with retry: false" do
    let(:inputs) { { order_id: "order_1", fail_at: :charge, retry_veto: :veto } }

    it "is terminal on the first attempt and rolls back immediately" do
      expect(reactor).to be_failure
      expect(reactor).to have_retried_step(:charge).times(0)
    end
  end

  context "fail! with the retry veto left alone" do
    let(:inputs) { { order_id: "order_1", fail_at: :charge, success_at_retry: 2 } }

    it "retries under the step's own budget and succeeds" do
      expect(reactor).to be_success
      expect(reactor).to have_retried_step(:charge).times(1)
    end
  end

  context "fail! exhausting the retry budget" do
    let(:inputs) { { order_id: "order_1", fail_at: :charge } }

    it "retries under the step's own budget before failing" do
      expect(reactor).to be_failure
      expect(reactor).to have_retried_step(:charge)
    end
  end

  context "failure after a skipped step" do
    let(:inputs) { { order_id: "order_1", skip_notify: true, fail_at: :finalize } }

    it "fails and rolls back, having actually run the skipped step" do
      expect(reactor).to be_failure
      expect(reactor).to have_run_step(:charge)
      expect(reactor).to have_run_step(:notify)
      expect(reactor).to be_skipped.at_step(:notify)
    end
  end
end
