# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Interrupt validation with max_attempts" do
  let(:reactor_class) { FormInterruptReactorReproduction }
  let(:user_name) { "test_user" }

  it "fails and compensates after exceeding max_attempts" do
    reactor_instance = reactor_class.new
    reactor_instance.run(user_name: user_name)
    reactor_id = reactor_instance.context.context_id

    # wait_for_approval has max_attempts 2

    # Attempt 1: Invalid
    begin
      reactor_class.continue(id: reactor_id, step_name: :wait_for_approval, payload: { invalid: true })
    rescue RubyReactor::Error::InputValidationError
      # Expected
    end

    context = reactor_class.find(reactor_id).context
    expect(context.status).to eq("paused")

    # Attempt 2: Invalid (Limit reached)
    # The current implementation plan says: perform undo, call cancel, return Failure
    # (which raises InputValidationError in class method but we might want to change that expectation or catch it)
    # If the class method raises InputValidationError, it might hide the fact that the reactor is now cancelled.
    # We need to check if Reactor.continue logic will differentiate between "validation failure, retry allowed"
    # and "validation failure, reactor dead".
    # For now, let's assume it raises Exception but we check status afterwards.

    begin
      reactor_class.continue(id: reactor_id, step_name: :wait_for_approval, payload: { invalid: true })
    rescue RubyReactor::Error::InputValidationError
      # Expected
    end

    reactor_class.find(reactor_id).context
    context = reactor_class.find(reactor_id).context
    expect(context.status).to eq("failed")

    failure_data = context.failure_reason
    expect(failure_data).to be_a(Hash)
    expect(failure_data[:message]).to include("Validation failed after 2 attempts")
    expect(failure_data[:step_name].to_s).to eq("wait_for_approval")
    expect(failure_data[:attempts]).to eq(2)
    # Payload is now in step_arguments
    expect(failure_data[:step_arguments] || failure_data[:payload]).to eq({ invalid: true })

    # Validation errors
    expect(failure_data[:validation_errors]).not_to be_empty
    expect(failure_data[:validation_errors]).to include(:user, :approved)

    expect(context.undo_stack).to be_empty # Should have been drained
  end

  it "succeeds if valid payload provided within max_attempts" do
    reactor_instance = reactor_class.new
    reactor_instance.run(user_name: user_name)
    reactor_id = reactor_instance.context.context_id

    # Satisfy the other interrupt first
    reactor_class.continue(id: reactor_id, step_name: :wait_for_user_input, payload: { bio: "test" })

    # Attempt 1: Invalid
    begin
      reactor_class.continue(id: reactor_id, step_name: :wait_for_approval, payload: { invalid: true })
    rescue RubyReactor::Error::InputValidationError
      # Expected
    end

    # Attempt 2: Valid
    valid_payload = { user: "admin", approved: true }
    reactor_class.continue(id: reactor_id, step_name: :wait_for_approval, payload: valid_payload)

    context = reactor_class.find(reactor_id).context
    expect(context.status).to eq("completed")
  end
end
