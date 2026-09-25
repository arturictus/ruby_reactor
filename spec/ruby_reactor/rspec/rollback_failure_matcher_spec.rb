# frozen_string_literal: true

require "spec_helper"

RSpec.describe "have_rollback_failure matcher" do
  let(:failure) do
    RubyReactor::Failure.new(
      "boom",
      rollback_failures: [
        { step: :charge, kind: :undo, key: "acct:1", reason: :coordination_unavailable, message: "busy" }
      ]
    )
  end

  it "matches a step listed on rollback_failures" do
    expect(failure).to have_rollback_failure(:charge)
  end

  it "does not match a step that rolled back cleanly" do
    expect(failure).not_to have_rollback_failure(:refund)
    expect(RubyReactor::Failure.new("boom")).not_to have_rollback_failure(:charge)
  end

  it "narrows by key with .for_key" do
    expect(failure).to have_rollback_failure(:charge).for_key("acct:1")
    expect(failure).not_to have_rollback_failure(:charge).for_key("acct:2")
  end

  it "narrows by reason with .because, and lists the actual entries when it does not match" do
    expect(failure).to have_rollback_failure(:charge).because(:coordination_unavailable)

    expect { expect(failure).to have_rollback_failure(:charge).because(:raised) }
      .to raise_error(RSpec::Expectations::ExpectationNotMetError, /because :raised, got rollback_failures.*acct:1/)
  end
end
