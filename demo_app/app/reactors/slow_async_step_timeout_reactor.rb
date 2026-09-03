# An `async_step` whose work takes long enough to exceed
# `RubyReactor.configuration.async_wait_timeout` (default 30s).
# :await_slow_task reads `result(:slow_task)`, so a synchronous caller (a rake
# task, a request thread) blocks in the notified wait; when the dispatched
# work outlives the bound, this step raises `Error::AsyncWaitTimeoutError`,
# which fails the reactor and compensates whatever already ran (see
# :acknowledge's `undo`).
#
# Contrast with `SlowAsyncStepReactor`, where nothing reads the slow step's
# result and the same slow work never blocks anyone.
class SlowAsyncStepTimeoutReactor < RubyReactor::Reactor
  input :job_id
  input :sleep_seconds

  async_step :slow_task do
    argument :job_id, input(:job_id)
    argument :sleep_seconds, input(:sleep_seconds)

    run do |args|
      Rails.logger.info "SlowAsyncStepTimeoutReactor: starting a #{args[:sleep_seconds]}s task for #{args[:job_id]}"
      sleep args[:sleep_seconds]
      Rails.logger.info "SlowAsyncStepTimeoutReactor: task for #{args[:job_id]} finished"
      Success({ job_id: args[:job_id], finished_at: Time.current.iso8601 })
    end
  end

  step :acknowledge do
    argument :job_id, input(:job_id)

    run do |args|
      Rails.logger.info "SlowAsyncStepTimeoutReactor: acknowledged #{args[:job_id]}"
      Success(:acknowledged)
    end

    undo do |_result, args, _ctx|
      Rails.logger.warn "SlowAsyncStepTimeoutReactor: undoing acknowledgement for #{args[:job_id]}"
      Success()
    end
  end

  step :await_slow_task do
    argument :task, result(:slow_task)

    run do |args|
      Success(args[:task])
    end
  end

  returns :await_slow_task
end
