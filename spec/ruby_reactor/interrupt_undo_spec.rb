# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Interrupt Compensation and Undo" do
  let(:reactor_class) { InterruptUndoTestReactor }

  before do
    # Clear trace/redis
    reactor_class.instance_variable_set(:@trace, [])
    # Clear Redis
    RubyReactor::Configuration.instance.storage_adapter.respond_to?(:flushdb) &&
      RubyReactor::Configuration.instance.storage_adapter.flushdb
  end

  describe "Validation Failure" do
    let(:execution) { reactor_class.run }
    let(:execution_id) do
      execution.execution_id
    end

    before do
      expect(execution).to be_a(RubyReactor::InterruptResult)
      expect(reactor_class.trace).to eq([:prepare_run])
    end

    context "via Reactor.continue (Class method)" do
      it "automatically undos and cancels on invalid payload" do
        # Action & Assertion
        expect do
          reactor_class.continue(id: execution_id, payload: { status: "invalid" }, step_name: :wait_for_input)
        end.to raise_error(RubyReactor::Error::InputValidationError)

        expect(reactor_class.trace).to include(:prepare_undo)

        stored = RubyReactor::Configuration.instance.storage_adapter.retrieve_context(execution_id, reactor_class.name)
        expect(stored).to be_nil
      end

      it "resumes successfully on valid payload" do
        result = reactor_class.continue(id: execution_id, payload: { status: "ok" }, step_name: :wait_for_input)

        expect(result).to be_a(RubyReactor::Success)
        expect(reactor_class.trace).to include(:process_run)
        expect(reactor_class.trace).not_to include(:prepare_undo)
      end
    end

    context "via reactor.continue (Instance method)" do
      it "returns invalid_payload result WITHOUT undo" do
        reactor = reactor_class.find(execution_id)

        result = reactor.continue(payload: { status: "invalid" }, step_name: :wait_for_input)

        expect(result).to be_a(RubyReactor::Failure)
        expect(result.invalid_payload?).to be true

        expect(reactor_class.trace).not_to include(:prepare_undo)

        stored = RubyReactor::Configuration.instance.storage_adapter.retrieve_context(execution_id, reactor_class.name)
        expect(stored).not_to be_nil
      end
    end
  end

  describe "Explicit Undo" do
    let(:execution) { reactor_class.run }
    let(:execution_id) { execution.execution_id }

    before do
      expect(execution).to be_a(RubyReactor::InterruptResult)
    end

    it "runs compensations and cancels execution" do
      expect(reactor_class.trace).to eq([:prepare_run])

      reactor_class.undo(execution_id)

      expect(reactor_class.trace).to include(:prepare_undo)

      stored = RubyReactor::Configuration.instance.storage_adapter.retrieve_context(execution_id, reactor_class.name)
      expect(stored).to be_nil
    end
  end

  describe "Explicit Cancel" do
    let(:execution) { reactor_class.run }
    let(:execution_id) { execution.execution_id }

    it "deletes execution WITHOUT compensation" do
      reactor_class.cancel(id: execution_id, reason: "Manual cancel")

      stored = RubyReactor::Configuration.instance.storage_adapter.retrieve_context(execution_id, reactor_class.name)
      expect(stored).to be_nil

      expect(reactor_class.trace).not_to include(:prepare_undo)
    end

    context "Explicit Step Validation" do
      it "resumes successfully when correct step_name is provided" do
        reactor_class = InterruptUndoTestReactor
        execution = reactor_class.run(user_id: "step_check_valid")
        execution_id = execution.execution_id

        # Resume with correct step name
        result = reactor_class.continue(
          id: execution_id,
          payload: { status: "ok" },
          step_name: :wait_for_input
        )

        expect(result).to be_a(RubyReactor::Success)
      end

      it "raises ValidationError when incorrect step_name is provided" do
        reactor_class = InterruptUndoTestReactor
        execution = reactor_class.run(user_id: "step_check_invalid")
        execution_id = execution.execution_id

        # Resume with incorrect step name
        expect do
          reactor_class.continue(
            id: execution_id,
            payload: { status: "ok" },
            step_name: :wrong_step
          )
        end.to raise_error(RubyReactor::Error::ValidationError,
                           /expected step 'wait_for_input' or ready steps .* but got 'wrong_step'/)
      end
    end
  end
end
