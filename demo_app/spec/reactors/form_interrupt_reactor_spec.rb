require "rails_helper"

RSpec.describe FormInterruptReactor, type: :reactor do
  subject(:reactor) { test_reactor(described_class, { user_name: "Alice" }) }

  it "pauses at the two interrupt steps after prepare_application" do
    expect(reactor).to be_paused
    expect(reactor).to have_ready_interrupts(:wait_for_user_input, :wait_for_approval)
  end

  it "resumes through both interrupts and finalizes" do
    reactor.resume(step: :wait_for_user_input, payload: { bio: "A bio" })
    reactor.resume(step: :wait_for_approval,   payload: { user: "admin", approved: true })

    expect(reactor).to be_success
    final = reactor.result.value
    expect(final[:status]).to eq("complete")
    expect(final[:additional_info]).to eq("A bio")
  end

  context "when prepare_application fails up front" do
    subject(:reactor) do
      test_reactor(described_class, { user_name: "Alice", fail_at: :prepare_application })
    end

    it "fails the reactor and never pauses" do
      expect(reactor).to be_failure
      expect(reactor).not_to be_paused
    end
  end
end
