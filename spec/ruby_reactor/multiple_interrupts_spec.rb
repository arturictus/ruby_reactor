# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Multiple Interrupts Reactor" do
  let(:reactor_class) { MultipleInterruptsReactor }

  before do
    reactor_class.instance_variable_set(:@trace, [])
    # Clear Redis
    RubyReactor::Configuration.instance.storage_adapter.respond_to?(:flushdb) &&
      RubyReactor::Configuration.instance.storage_adapter.flushdb
  end

  describe "Phase 1: Concurrent Approvals" do
    it "pauses for multiple interrupts and resumes when all are satisfied (Sequential)" do
      # Initial run
      execution = reactor_class.run
      execution_id = execution.execution_id

      expect(execution).to be_a(RubyReactor::InterruptResult)
      expect(reactor_class.trace).to eq([:initiate_transaction])

      # Resume Manager One
      result_one = reactor_class.continue(
        id: execution_id,
        step_name: :manager_one_approval,
        payload: { status: "approved" }
      )

      expect(result_one).to be_a(RubyReactor::InterruptResult)

      # Resume Manager Two
      result_two = reactor_class.continue(
        id: execution_id,
        step_name: :manager_two_approval,
        payload: { status: "approved" }
      )

      # Should complete Phase 1 and move to Phase 2 (paused at final_approval_1 or 2)
      expect(result_two).to be_a(RubyReactor::InterruptResult)
      expect(reactor_class.trace).to include(:complete_transaction, :processing_phase_2)
    end

    it "pauses for multiple interrupts and resumes in INDIFFERENT order" do
      # Initial run
      execution = reactor_class.run
      execution_id = execution.execution_id

      expect(execution).to be_a(RubyReactor::InterruptResult)

      # Resume Manager TWO first (out of definition order)
      result_one = reactor_class.continue(
        id: execution_id,
        step_name: :manager_two_approval,
        payload: { status: "approved" }
      )

      expect(result_one).to be_a(RubyReactor::InterruptResult)

      # Resume Manager ONE second
      result_two = reactor_class.continue(
        id: execution_id,
        step_name: :manager_one_approval,
        payload: { status: "approved" }
      )

      # Should complete Phase 1 and move to Phase 2
      expect(result_two).to be_a(RubyReactor::InterruptResult)
      expect(reactor_class.trace).to include(:complete_transaction, :processing_phase_2)
    end
  end

  describe "Phase 2: Premature Execution Prevention" do
    it "prevents continuing a future interrupt that is not ready" do
      # Initial run -> Paused at Phase 1 approvals
      execution = reactor_class.run
      execution_id = execution.execution_id

      # Try to approve Phase 2 (final_approval_1) BEFORE Phase 1 is done
      expect do
        reactor_class.continue(
          id: execution_id,
          step_name: :final_approval_1,
          payload: { status: "final_ok" }
        )
      end.to raise_error(RubyReactor::Error::ValidationError,
                         /Cannot resume: expected step .* or ready steps .* but got 'final_approval_1'/)
    end
  end

  describe "Full Workflow" do
    it "completes the full multi-phase workflow" do
      execution = reactor_class.run
      id = execution.execution_id

      # Phase 1
      reactor_class.continue(id: id, step_name: :manager_one_approval, payload: { status: "approved" })
      reactor_class.continue(id: id, step_name: :manager_two_approval, payload: { status: "approved" })

      # Phase 2
      # Resume Final 1
      reactor_class.continue(id: id, step_name: :final_approval_1, payload: { status: "final_ok" })

      # Resume Final 2 -> Completion
      result = reactor_class.continue(id: id, step_name: :final_approval_2, payload: { status: "final_ok" })

      expect(result).to be_a(RubyReactor::Success)
      expect(result.value).to eq("done")
      expect(reactor_class.trace).to eq(%i[
                                          initiate_transaction
                                          complete_transaction
                                          processing_phase_2
                                          final_completion
                                        ])
    end
  end
end
