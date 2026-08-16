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
        sidekiq_options retry: RubyReactor.configuration.job_retry_count, dead: false,
                        queue: RubyReactor.configuration.queue_name

        sidekiq_retries_exhausted do |_, _exception|
          # Handle infrastructure failures (network, Redis, etc.)
        end
      end
    end
  end
end
