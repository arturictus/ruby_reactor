# frozen_string_literal: true

require "rails_helper"

# 011 US4: runs are kept in the database and found by input value; the
# redacted card token is never searchable.
RSpec.describe ActiveRecordHistoryReactor, :active_record_only, type: :reactor do
  it "keeps a successful run findable by its user" do
    reactor = test_reactor(described_class, { user_id: 100, card_token: "tok_visa" })

    expect(reactor).to be_success
    expect(reactor).to be_findable_by(user_id: 100)
    expect(reactor).not_to be_findable_by(user_id: 200)
  end

  it "never finds a run by its redacted card token" do
    reactor = test_reactor(described_class, { user_id: 100, card_token: "tok_visa" })

    expect(reactor).to be_success
    expect(reactor).not_to be_findable_by(card_token: "tok_visa")
  end

  it "keeps a declined, compensated run in history too" do
    reactor = test_reactor(described_class, { user_id: 300, card_token: "tok_visa", decline: true })

    expect(reactor).to be_failure
    expect(reactor).to have_run_step(:reserve)
    expect(reactor).to be_findable_by(user_id: 300)
  end
end
