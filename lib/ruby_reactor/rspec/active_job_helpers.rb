# frozen_string_literal: true

module RubyReactor
  module RSpec
    # ActiveJob counterpart to `SidekiqHelpers`, used internally by
    # `AsyncTestHelpers` to drain the ActiveJob `:test` queue adapter. Only
    # the static methods are needed (`AsyncTestHelpers` dispatches to them);
    # `Rails::ActiveJob::TestHelper` already covers most spec-author-facing
    # assertions, so this module is not auto-included into examples.
    module ActiveJobHelpers
      PendingJob = Struct.new(:job_class, :raw) do
        def perform!
          ::ActiveJob::Base.queue_adapter.enqueued_jobs.delete(raw)
          job_class.new(*raw[:args]).perform_now
        end

        def args
          raw[:args]
        end
      end

      def self.test_adapter?
        defined?(::ActiveJob::Base) &&
          ::ActiveJob::Base.queue_adapter.is_a?(::ActiveJob::QueueAdapters::TestAdapter)
      end

      # Drain every queued job in the ActiveJob `:test` adapter until the
      # queue is empty. Recursive — handles jobs that re-enqueue themselves
      # (e.g. ordered_lock snoozes) and job chains that queue additional jobs.
      def self.drain_async_jobs(max_iterations: 100)
        return unless test_adapter?

        queue = ::ActiveJob::Base.queue_adapter.enqueued_jobs

        max_iterations.times do
          break if queue.empty?

          queue.dup.each do |job|
            queue.delete(job)
            job[:job].new(*job[:args]).perform_now
          end
        end
      end

      def self.pending_async_jobs
        return [] unless test_adapter?

        ::ActiveJob::Base.queue_adapter.enqueued_jobs.map { |raw| PendingJob.new(raw[:job], raw) }
      end
    end
  end
end
