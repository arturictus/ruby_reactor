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
        retry_on StandardError, attempts: RubyReactor.configuration.job_retry_count
      end
    end
  end
end
