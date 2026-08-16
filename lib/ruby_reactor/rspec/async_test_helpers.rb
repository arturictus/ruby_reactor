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
        if sidekiq_testing?
          SidekiqHelpers.drain_async_jobs(max_iterations: max_iterations)
        elsif active_job_testing?
          ActiveJobHelpers.drain_async_jobs(max_iterations: max_iterations)
        end
      end

      def self.pending_async_jobs
        if sidekiq_testing?
          SidekiqHelpers.pending_async_jobs
        elsif active_job_testing?
          ActiveJobHelpers.pending_async_jobs
        else
          []
        end
      end
    end
  end
end
