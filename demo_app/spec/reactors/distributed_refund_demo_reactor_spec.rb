require "rails_helper"

RSpec.describe DistributedRefundDemoReactor, type: :reactor do
  before { described_class.reset! }

  def perform_until_rollback_queued
    until pending_async_jobs.any? { |job| job.worker_class.name.end_with?("MapElementRollbackWorker") }
      pending_async_jobs.first.perform!
    end
  end

  it "refunds every charged order with its own rollback job, then fails" do
    subject = test_reactor(described_class, { fail_notify: true }, process_jobs: false)
    subject.run
    perform_until_rollback_queued

    expect(subject).to be_rolling_back

    drain_async_jobs
    expect(subject).to be_failure
    expect(described_class.charges.size).to eq(40)
    expect(described_class.refunds.sort).to eq(described_class.charges.sort)
  end

  it "keeps every charge when nothing fails" do
    subject = test_reactor(described_class, {})

    expect(subject).to be_success
    expect(described_class.refunds).to be_empty
  end
end
