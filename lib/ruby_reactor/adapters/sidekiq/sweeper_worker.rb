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
        sidekiq_options retry: false

        # Read when each tick is enqueued, not at class load (011 F-1).
        def self.get_sidekiq_options # rubocop:disable Naming/AccessorMethodName -- overrides Sidekiq's own method
          super.merge("queue" => RubyReactor.configuration.queue_name.to_s)
        end
      end
    end
  end
end
