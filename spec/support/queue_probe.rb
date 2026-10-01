# frozen_string_literal: true

# Back-pressure probe for the fan-out specs, on either in-memory backend. The
# bound is per throw (009 FR-002, R-02): no single job enqueues more than the
# batch size. Queue depth is deliberately not reported — a FIFO drain would
# make any depth assertion pass by accident.
#
#   QueueProbe.drain_tracking("MapElementRollbackWorker") # => { max_burst: 5 }
module QueueProbe
  module_function

  # Jobs of the class whose name ends with `worker_class_name` now queued.
  def enqueued(worker_class_name)
    pending.count { |job| class_of(job).name.end_with?(worker_class_name) }
  end

  # Performs every queued job, oldest first, one at a time, until none remain.
  # `max_burst` is the most jobs of that class one job enqueued, counting the
  # jobs already queued when the drain starts (the first throw).
  def drain_tracking(worker_class_name, max_jobs: 100_000)
    max_burst = enqueued(worker_class_name)
    max_jobs.times do
      job = next_job
      break unless job

      before = enqueued(worker_class_name) - (class_of(job).name.end_with?(worker_class_name) ? 1 : 0)
      job.perform!
      max_burst = [max_burst, enqueued(worker_class_name) - before].max
    end
    { max_burst: max_burst }
  end

  def pending
    RubyReactor::RSpec::AsyncTestHelpers.pending_async_jobs
  end

  # Sidekiq keeps one queue per worker class, so order by creation time.
  def next_job
    jobs = pending
    return jobs.first unless RubyReactor::RSpec::AsyncTestHelpers.sidekiq_testing?

    jobs.min_by { |job| job.raw["created_at"].to_f }
  end

  def class_of(job)
    job.respond_to?(:worker_class) ? job.worker_class : job.job_class
  end
end
