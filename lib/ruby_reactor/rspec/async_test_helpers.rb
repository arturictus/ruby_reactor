# frozen_string_literal: true

module RubyReactor
  module RSpec
    # Single entry point `TestSubject` uses to detect and drain whichever
    # async testing framework — Sidekiq::Testing fake mode or ActiveJob's
    # `:test` queue adapter — is currently active, so the job-processing gate
    # isn't hardcoded to one background processor.
    module AsyncTestHelpers
      def self.active?
        sidekiq_testing? || active_job_testing?
      end

      def self.sidekiq_testing?
        defined?(::Sidekiq::Testing) && ::Sidekiq::Testing.fake?
      end

      def self.active_job_testing?
        ActiveJobHelpers.test_adapter?
      end

      def self.drain_async_jobs(max_iterations: 100)
        case backend
        when :sidekiq then SidekiqHelpers.drain_async_jobs(max_iterations: max_iterations)
        when :active_job then ActiveJobHelpers.drain_async_jobs(max_iterations: max_iterations)
        end
      end

      def self.pending_async_jobs
        case backend
        when :sidekiq then SidekiqHelpers.pending_async_jobs
        when :active_job then ActiveJobHelpers.pending_async_jobs
        else []
        end
      end

      # The queue the configured router actually enqueues to. An app can load
      # sidekiq/testing (fake mode) yet route reactors through ActiveJob; its
      # jobs then sit in the ActiveJob :test queue, so that is the one to drain.
      def self.backend
        active_job_router = ::RubyReactor.configuration.async_router.to_s.start_with?("RubyReactor::Adapters::ActiveJob")
        return :active_job if active_job_router && active_job_testing?
        return :sidekiq if sidekiq_testing?

        :active_job if active_job_testing?
      end
    end
  end
end
