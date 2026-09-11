# frozen_string_literal: true

require "spec_helper"

# FR-003 on the paths that leave the calling process: an `async_step` body runs
# in StepWorker, and `background all: true` runs the whole reactor in a worker.
# Both against a real worker, never Sidekiq::Testing.inline!.
RSpec.describe "Step input contracts in the worker" do
  def eventually(timeout: 15, interval: 0.2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      value = yield
      return value if value
      raise "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep interval
    end
  end

  before { StepContractFixtures.reset! }

  for_each_real_async_backend do
    describe "async_step with a contract-owning step class" do
      it "fails inside the worker with a structured, non-retryable validation failure" do
        result = ContractAsyncStepReactor.run(amount: 0, currency: "USD")

        expect(result).to be_failure
        worker_failure = StepContractFixtures.received.first
        expect(worker_failure).to be_a(RubyReactor::Failure)
        expect(worker_failure.validation_errors).to have_key(:amount)
        expect(worker_failure.step_name.to_s).to eq("charge")
        expect(worker_failure.retryable?).to be(false)
      end

      it "keeps the validation errors on the reactor's failure when the reader propagates it" do
        result = ContractAsyncStepReactor.run(amount: 0, currency: "USD")

        expect(result.validation_errors).to have_key(:amount)
        expect(test_reactor(ContractAsyncStepReactor, { amount: 0, currency: "USD" }))
          .to have_validation_error(:amount)
      end

      it "succeeds with conforming values" do
        result = ContractAsyncStepReactor.run(amount: 5, currency: "USD")

        expect(result).to be_success
        expect(result.value).to eq(amount: 5, currency: "USD")
      end
    end

    describe "async_step with an inline inputs block" do
      it "fails inside the worker exactly like the class form" do
        ContractInlineAsyncReactor.run(amount: 0, currency: "USD")

        worker_failure = StepContractFixtures.received.first
        expect(worker_failure).to be_a(RubyReactor::Failure)
        expect(worker_failure.validation_errors).to have_key(:amount)
        expect(worker_failure.step_name.to_s).to eq("charge")
        expect(worker_failure.retryable?).to be(false)
      end
    end

    describe "async_step resolved by name, with no argument lines" do
      it "receives the reactor inputs in the worker" do
        result = ContractNameResolvedAsyncReactor.run(amount: 5, currency: "USD")

        expect(result).to be_success
        expect(result.value).to eq(amount: 5, currency: "USD")
      end

      it "fails with the contract's errors in the worker" do
        ContractNameResolvedAsyncReactor.run(amount: 0, currency: "USD")

        expect(StepContractFixtures.received.first.validation_errors).to have_key(:amount)
      end
    end

    describe "background all: true" do
      it "fails the same way inside the hand-off worker" do
        dispatch = ContractBackgroundReactor.run(amount: 0, currency: "USD")

        failure = eventually do
          reactor = ContractBackgroundReactor.find(dispatch.execution_id)
          reactor.result if reactor.context.status.to_s == "failed"
        end
        expect(failure.validation_errors).to have_key(:amount)
        expect(failure.step_name.to_s).to eq("charge")
      end
    end
  end
end
