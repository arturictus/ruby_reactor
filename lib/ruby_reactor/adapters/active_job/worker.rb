# frozen_string_literal: true

require "active_job"

module RubyReactor
  module Adapters
    module ActiveJob
      # ActiveJob worker for executing RubyReactor reactors asynchronously.
      # All resume/snooze/escalate logic lives in `RubyReactor::Worker` — this
      # class only wires it to ActiveJob.
      #
      # Infra-failure retries only: reactor-specific contention/config errors
      # are already rescued inside `RubyReactor::Worker#perform` (snoozed or
      # escalated to `failed`) before they'd ever reach this `retry_on`.
      class Worker < ::ActiveJob::Base
        extend Compat
        include RubyReactor::Worker

        queue_as { RubyReactor.configuration.queue_name }
        retry_on StandardError, attempts: RubyReactor.configuration.job_retry_count do |job, error|
          # Attempts exhausted and the job is done for — mark the context
          # failed and signal any reader waiting on it (mirrors the Sidekiq
          # adapter's retries-exhausted hook).
          RubyReactor::Worker.record_retries_exhausted(job.arguments, error)
        end
      end
    end
  end
end
