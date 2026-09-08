# frozen_string_literal: true

module RubyReactor
  module RSpec
    # Async-job manipulation helpers. Names like `drain_async_jobs` are too
    # generic to live in the global spec namespace, so this module is only
    # auto-included into examples tagged `type: :reactor`. Specs that need it
    # outside that tag should `include RubyReactor::RSpec::SidekiqHelpers`
    # explicitly.
    module SidekiqHelpers
      # Drain every queued async job across all RubyReactor worker classes
      # until the queues are empty. Recursive — handles jobs that re-enqueue
      # themselves (e.g. ordered_lock snoozes) and worker chains that queue
      # additional jobs.
      def drain_async_jobs(max_iterations: 100)
        SidekiqHelpers.drain_async_jobs(max_iterations: max_iterations)
      end

      # All currently-pending async jobs, wrapped in `PendingJob` so callers
      # can perform individual jobs out-of-order (e.g. to assert
      # ordered_lock's snooze behavior) without touching Sidekiq internals.
      def pending_async_jobs
        SidekiqHelpers.pending_async_jobs
      end

      PendingJob = Struct.new(:worker_class, :raw) do
        def perform!
          worker_class.jobs.delete(raw)
          worker_class.new.perform(*raw["args"])
        end

        def args
          raw["args"]
        end
      end

      def self.worker_classes
        @worker_classes ||= [
          RubyReactor::Adapters::Sidekiq::Worker,
          RubyReactor::Adapters::Sidekiq::MapElementWorker,
          RubyReactor::Adapters::Sidekiq::MapCollectorWorker,
          RubyReactor::Adapters::Sidekiq::StepWorker
        ]
      end

      def self.drain_async_jobs(max_iterations: 100)
        return unless defined?(Sidekiq::Testing)

        max_iterations.times do
          processed_any = false
          worker_classes.each do |worker_class|
            while (job = worker_class.jobs.shift)
              worker_class.new.perform(*job["args"])
              processed_any = true
            end
          end

          break unless processed_any
        end
      end

      def self.pending_async_jobs
        return [] unless defined?(Sidekiq::Testing)

        worker_classes.flat_map do |worker_class|
          worker_class.jobs.map { |raw| PendingJob.new(worker_class, raw) }
        end
      end
    end
  end
end
