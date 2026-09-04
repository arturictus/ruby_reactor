# An `async_step` whose work takes a long time (a real `sleep`, here 35s in
# the rake demo). Nothing in this reactor reads `result(:slow_task)` — just
# like a fire-and-forget `async_reactor` — so it returns as soon as
# :acknowledge finishes, regardless of how long the dispatched work actually
# takes to complete in its own job.
#
# Contrast with `SlowAsyncStepTimeoutReactor`, which DOES read the result and
# shows what happens when that same slow work is awaited instead.
class SlowAsyncStepReactor < RubyReactor::Reactor
  input :job_id
  input :sleep_seconds

  async_step :slow_task do
    argument :job_id, input(:job_id)
    argument :sleep_seconds, input(:sleep_seconds)

    run do |args|
      Rails.logger.info "SlowAsyncStepReactor: starting a #{args[:sleep_seconds]}s task for #{args[:job_id]}"
      sleep args[:sleep_seconds]
      Rails.logger.info "SlowAsyncStepReactor: task for #{args[:job_id]} finished"
      Success({ job_id: args[:job_id], finished_at: Time.current.iso8601 })
    end
  end

  step :acknowledge do
    argument :job_id, input(:job_id)

    run do |args|
      Rails.logger.info "SlowAsyncStepReactor: acknowledged #{args[:job_id]} without waiting on the slow task"
      Success(:acknowledged)
    end
  end

  returns :acknowledge
end
