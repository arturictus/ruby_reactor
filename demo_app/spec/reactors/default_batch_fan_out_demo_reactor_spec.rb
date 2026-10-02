require "rails_helper"

RSpec.describe DefaultBatchFanOutDemoReactor, type: :reactor do
  it "enqueues at most 50 element jobs per throw without a declared batch_size, and collects all 120" do
    subject = test_reactor(described_class, {}, process_jobs: false)
    subject.run
    expect(pending_async_jobs.count { |job| job.worker_class.name.end_with?("MapElementWorker") }).to eq(50)

    drain_async_jobs
    expect(subject).to be_success
    expect(subject.step_result(:doubled)).to eq(120)
  end
end
