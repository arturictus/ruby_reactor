# frozen_string_literal: true

require "spec_helper"

# 009 API §RSpec: `be_rolling_back` for a run handed off at a fan-out map, and
# step-wise draining through `pending_async_jobs` on either backend.
module BeRollingBackSpec
  MapRollbackFixtures.parent(self, :Later, MapRollbackFixtures::ElemOk, fan_out: true, batch_size: 2, b_fails: true)
end

RSpec.describe "be_rolling_back", type: :reactor do
  def perform_until_rollback_queued
    100.times do
      return if pending_async_jobs.any? { |job| job.worker_class.name.end_with?("MapElementRollbackWorker") }

      pending_async_jobs.first.perform!
    end
  end

  for_each_async_backend do
    it "matches while element rollbacks are pending, and not once they are drained" do
      subject = test_reactor(BeRollingBackSpec::Later, { items: [0, 1, 2, 3] }, process_jobs: false)
      subject.run

      perform_until_rollback_queued

      expect(subject).to be_rolling_back
      drain_async_jobs(max_iterations: 200)
      expect(subject).not_to be_rolling_back
      expect(subject).to be_failure
    end
  end

  it "names the job class worker_class on the ActiveJob backend" do
    original = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    Sidekiq::Testing.disable!
    RubyReactor::Adapters::ActiveJob::Router.perform_async("id", "Klass")

    expect(pending_async_jobs.map(&:worker_class)).to eq([RubyReactor::Adapters::ActiveJob::Worker])
  ensure
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    ActiveJob::Base.queue_adapter = original
  end
end
