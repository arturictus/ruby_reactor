require "rails_helper"

RSpec.describe DistributedRefundDemoReactor, type: :reactor do
  before { described_class.reset! }

  def pending_jobs(worker)
    pending_async_jobs.count { |job| job.worker_class.name.end_with?(worker) }
  end

  def perform_until_rollback_queued
    pending_async_jobs.first.perform! while pending_jobs("MapElementRollbackWorker").zero?
  end

  it "refunds every charged order with its own rollback job, at most 10 per throw, then fails" do
    subject = test_reactor(described_class, { fail_notify: true }, process_jobs: false)
    subject.run
    expect(pending_jobs("MapElementWorker")).to eq(10)

    perform_until_rollback_queued
    expect(subject).to be_rolling_back
    expect(pending_jobs("MapElementRollbackWorker")).to eq(10)

    drain_async_jobs
    expect(subject).to be_failure
    expect(described_class.charges.size).to eq(40)
    expect(described_class.refunds.sort).to eq(described_class.charges.sort)
  end

  it "keeps every charge when nothing fails" do
    subject = test_reactor(described_class, {})

    expect(subject).to be_success
    expect(subject).to have_run_step(:notify).after(:charge_orders)
    expect(described_class.refunds).to be_empty
  end
end
