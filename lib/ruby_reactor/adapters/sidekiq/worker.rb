# frozen_string_literal: true

require "sidekiq"

module RubyReactor
  module Adapters
    module Sidekiq
      # Sidekiq worker for executing RubyReactor reactors asynchronously
      # with non-blocking retry capabilities. All resume/snooze/escalate logic
      # lives in `RubyReactor::Worker` — this class only wires it to Sidekiq.
      class Worker
        include ::Sidekiq::Worker
        include RubyReactor::Worker

        # Enable Sidekiq retries for infrastructure failures only
        sidekiq_options retry: RubyReactor.configuration.job_retry_count, dead: false

        # The queue is read when each job is built, not when this class loads
        # (011 F-1): a `queue_name` configured afterwards — a Rails initializer
        # runs after Bundler required the gem — still counts, for the router's
        # jobs and this worker's own snoozes alike.
        def self.get_sidekiq_options # rubocop:disable Naming/AccessorMethodName -- overrides Sidekiq's own method
          super.merge("queue" => RubyReactor.configuration.queue_name.to_s)
        end

        sidekiq_retries_exhausted do |msg, exception|
          # With `dead: false` this job is discarded after its last retry, so
          # this hook is the only place left to surface the failure: mark the
          # context failed and signal any reader waiting on it.
          RubyReactor::Worker.record_retries_exhausted(msg["args"], exception)
        end
      end
    end
  end
end
