require "rails_helper"

RSpec.describe BulkRefundDemoReactor, type: :reactor do
  before { described_class.reset! }

  it "refunds every completed charge with one undo_all call when settling fails" do
    reactor = test_reactor(described_class, { count: 6, fail_settle: true })

    expect(reactor).to be_failure
    expect(reactor).to have_run_undo_all(:charges).with_elements(6)
  end

  it "never calls undo_all when the run succeeds" do
    reactor = test_reactor(described_class, { count: 6 })

    expect(reactor).to be_success
    expect(reactor).not_to have_run_undo_all(:charges)
  end
end
