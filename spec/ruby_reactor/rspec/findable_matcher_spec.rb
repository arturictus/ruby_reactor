# frozen_string_literal: true

require "spec_helper"

class FindableMatcherReactor < RubyReactor::Reactor
  input :user_id
  input :card_token, redact: true

  step :charge do
    argument :user_id, input(:user_id)
    run { |args, _ctx| RubyReactor.Success(args.user_id) }
  end
end

# 011 US4: `be_findable_by(**inputs)` is the dashboard's input filter, from a spec.
RSpec.describe "be_findable_by", type: :reactor do
  it "finds a run by its inputs, never by a redacted one", :active_record_only do
    subject = test_reactor(FindableMatcherReactor, { user_id: 100, card_token: "tok" })

    expect(subject).to be_findable_by(user_id: 100)
    expect(subject).not_to be_findable_by(user_id: 200)
    expect(subject).not_to be_findable_by(card_token: "tok")
  end

  it "explains that history queries need the ActiveRecord adapter", :redis_only do
    subject = test_reactor(FindableMatcherReactor, { user_id: 100, card_token: "tok" })

    expect { expect(subject).to be_findable_by(user_id: 100) }.to raise_error(ArgumentError, /active_record/)
  end
end
