# frozen_string_literal: true

require_relative "rspec/helpers"
require_relative "rspec/matchers"
require_relative "rspec/sidekiq_helpers"
require_relative "rspec/active_job_helpers"
require_relative "rspec/async_test_helpers"
require_relative "rspec/storage_reset"
require_relative "rspec/test_subject"

module RubyReactor
  module RSpec
    # Examples opt into RubyReactor's RSpec setup (Sidekiq fake mode,
    # storage wipe, snooze knob reset) by declaring `type: :reactor`.
    REACTOR_METADATA = { type: :reactor }.freeze

    DEFAULT_SNOOZE_BASE_DELAY = 5
    DEFAULT_SNOOZE_JITTER = 5
    DEFAULT_SNOOZE_MAX_ATTEMPTS = 20

    def self.configure(config)
      require_relative "rspec/step_executor_patch"

      config.include RubyReactor::RSpec::Helpers
      config.include RubyReactor::RSpec::Matchers
      config.include RubyReactor::RSpec::SidekiqHelpers, REACTOR_METADATA

      ::RubyReactor::Executor::StepExecutor.prepend(RubyReactor::RSpec::StepExecutorPatch)
      StorageReset.install!

      config.before(:each, REACTOR_METADATA) do
        RubyReactor::RSpec.prepare_example!
      end
    end

    # Idempotent setup invoked before each `type: :reactor` example. Restores
    # Sidekiq fake mode, clears the queues, wipes the storage adapter, and
    # rolls back snooze knobs so cross-example bleed-through can't happen.
    def self.prepare_example!
      if defined?(::Sidekiq::Testing)
        begin
          ::Sidekiq::Testing.fake! unless ::Sidekiq::Testing.fake?
        rescue ::Sidekiq::Testing::TestModeAlreadySetError
          # Nested fake!/inline! block already active in this thread; leave it.
        end
        ::Sidekiq::Worker.clear_all
      end

      ::ActiveJob::Base.queue_adapter.enqueued_jobs.clear if AsyncTestHelpers.active_job_testing?

      adapter = ::RubyReactor.configuration.storage_adapter
      adapter.reset! if adapter.respond_to?(:reset!)

      ::RubyReactor.configuration.lock_snooze_base_delay = DEFAULT_SNOOZE_BASE_DELAY
      ::RubyReactor.configuration.lock_snooze_jitter = DEFAULT_SNOOZE_JITTER
      ::RubyReactor.configuration.lock_snooze_max_attempts = DEFAULT_SNOOZE_MAX_ATTEMPTS
    end
  end
end
