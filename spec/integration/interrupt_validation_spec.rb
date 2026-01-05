require "spec_helper"

RSpec.describe "Interrupt validation logic" do
  let(:reactor_class) { FormInterruptReactorReproduction }
  let(:user_name) { "test_user" }

  it "enforces validation on interrupt steps and maintains paused state on failure" do
    # 1. Start the reactor
    # It should run :prepare_application and then pause at :wait_for_user_input and :wait_for_approval
    execution_result = reactor_class.run(user_name: user_name)

    # Depending on how the reactor is implemented, it might return the result of the last executed step
    # or the reactor itself if it's paused.
    # In RubyReactor, run usually returns the final Result if completed, or an AsyncResult/PausedResult?
    # Actually, run returns:
    # - Success if finished
    # - Failure if failed
    # - If paused, it might be implicit in how we handle it.
    # But usually for interrupts, the reactor loop finishes and persists the state.

    # Let's verify we can find the reactor in Redis/Storage
    # It returns an InterruptResult when paused
    expect(execution_result).to be_a(RubyReactor::InterruptResult)
    # Or does it return a specialized result for Paused?
    # Based on previous tasks, it seems `run` returns Success/Failure of the *execution attempt*.
    # If it pauses, it's considered "successfully started/ran until pause".
    # We need the reactor_id.

    # We can get the reactor_id from the context of the instance if we had access,
    # but `run` is class method.
    # Let's look at `spec/ruby_reactor_spec.rb` again? No, it doesn't show interrupt usage.
    # But `reactor_class.new.run` does give us instance access.

    reactor_instance = reactor_class.new
    execution_result = reactor_instance.run(user_name: user_name)

    expect(execution_result).to be_a(RubyReactor::InterruptResult)

    reactor_id = reactor_instance.context.context_id
    expect(reactor_id).not_to be_nil

    # Verify status is paused (in storage)
    # We need to re-fetch context or trust the current one if not updated?
    # Context is updated in place usually.
    # But let's fetch fresh state to be sure.
    stored_context = reactor_class.find(reactor_id).context
    expect(stored_context.status).to eq("paused")

    # 2. Supply invalid payload for `wait_for_approval`
    # payload missing required fields 'user' and 'approved'
    invalid_payload = { something: "else" }

    # We expect this to raise an error or return a Failure indicating validation error
    # And IMPORTANTLY: The reactor status should remain 'paused'.

    begin
      reactor_class.continue(id: reactor_id, step_name: :wait_for_approval, payload: invalid_payload)
      raise "Should have raised an error or returned failure for invalid payload"
    rescue RubyReactor::Error::InputValidationError => e
      expect(e.message).to include("Input validation failed")
    end

    # Check state is still paused
    stored_context = reactor_class.find(reactor_id).context
    expect(stored_context.status).to eq("paused")

    # 3. Supply valid payload for `wait_for_user_input`
    # This is another interrupt step. Resuming it should work.
    # But it should NOT cause `wait_for_approval` to be skipped or the reactor to finish if `wait_for_approval` is still needed.

    valid_user_payload = { bio: "I am a tester" }
    continue_result = reactor_class.continue(id: reactor_id, step_name: :wait_for_user_input,
                                             payload: valid_user_payload)
    expect(continue_result).to be_a(RubyReactor::InterruptResult)

    # 4. Supply VALID payload for `wait_for_approval`
    # Now we provide the valid payload we failed to provide earlier.
    valid_approval_payload = { user: "admin", approved: true }

    # The reactor should be able to accept this now.
    final_result = reactor_class.continue(id: reactor_id, step_name: :wait_for_approval,
                                          payload: valid_approval_payload)
    expect(final_result).to be_a(RubyReactor::Success)

    # 5. Verify reactor completed successfully
    stored_context = reactor_class.find(reactor_id).context
    expect(stored_context.status).to eq("completed")
    expect(stored_context.result(:finalize_application)[:status]).to eq("complete")
  end
end
