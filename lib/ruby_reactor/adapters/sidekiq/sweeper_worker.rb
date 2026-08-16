# frozen_string_literal: true

require "sidekiq"

module RubyReactor
  module Adapters
    module Sidekiq
      class SweeperWorker
        include ::Sidekiq::Worker
        include RubyReactor::SweeperJob

        # retry: false — the sweep is idempotent and self-rescheduling, so a failed
        # tick must not pile up Sidekiq retries; the next tick (or a super_fetch
        # recovery) re-runs it anyway.
        sidekiq_options retry: false, queue: RubyReactor.configuration.queue_name
      end
    end
  end
end
