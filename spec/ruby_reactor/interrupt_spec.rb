# frozen_string_literal: true

require "spec_helper"

RSpec.describe "RubyReactor Interrupt Feature", type: :integration do
  let(:redis) { Redis.new(url: "redis://localhost:6780") }

  before do
    redis.flushdb
  end

  describe "execution flow" do
    it "pauses at interrupt step and resumes with payload" do
      # 1. Start execution
      execution = TestInterruptReactor.run(user_id: "123")

      # 2. Verify it paused
      expect(execution).to be_a(RubyReactor::InterruptResult)
      expect(execution.status).to eq(:paused)
      expect(execution.status).to eq(:paused)
      expect(execution.correlation_id).to eq("approval-prepared-123")
      expect(execution.intermediate_results).to include(prepare: "prepared-123")

      # 3. Verify state in Redis
      context_id = execution.execution_id
      stored_context = redis.get("reactor:TestInterruptReactor:context:#{context_id}")
      expect(stored_context).not_to be_nil

      # Verify correlation ID mapping
      stored_id = redis.get("reactor:TestInterruptReactor:correlation:approval-prepared-123")
      expect(stored_id).to eq(context_id)

      # 4. Resume execution via continue
      payload = { status: "approved", approver: "admin" }
      result = TestInterruptReactor.continue(id: context_id, payload: payload, step_name: :wait_for_approval)

      # 5. Verify completion
      expect(result).to be_a(RubyReactor::Success)
      expect(result.value[:finalize]).to eq("finalized-approved-by-admin")
    end

    it "resumes via correlation_id" do
      # 1. Start execution
      execution = TestInterruptReactor.run(user_id: "456")
      expect(execution).to be_a(RubyReactor::InterruptResult)

      # 2. Resume via correlation_id
      payload = { status: "rejected", approver: "system" }
      result = TestInterruptReactor.continue_by_correlation_id(
        correlation_id: "approval-prepared-456",
        payload: payload,
        step_name: :wait_for_approval
      )

      # 3. Verify completion
      expect(result).to be_a(RubyReactor::Success)
      expect(result.value[:finalize]).to eq("finalized-rejected-by-system")
    end

    it "validates payload on resume and fails after max attempts" do
      execution = TestInterruptReactor.run(user_id: "789")

      # Invalid payload (missing approver)
      payload = { status: "approved" }

      # Attempt 1: Should raise validation error (retryable)
      expect do
        TestInterruptReactor.continue(id: execution.execution_id, payload: payload, step_name: :wait_for_approval)
      end.to raise_error(RubyReactor::Error::InputValidationError)

      # Attempt 2: Should fail the reactor (max attempts reached)
      result = TestInterruptReactor.continue(id: execution.execution_id, payload: payload,
                                             step_name: :wait_for_approval)

      expect(result).to be_a(RubyReactor::Failure)
      expect(result.message).to include("Validation failed after 2 attempts")

      # Verify reactor status
      context = TestInterruptReactor.find(execution.execution_id).context
      expect(context.status).to eq("failed")
      expect(context.failure_reason[:validation_errors]).to include(:approver)
    end
  end
end
