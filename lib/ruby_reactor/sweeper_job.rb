# frozen_string_literal: true

require "securerandom"

module RubyReactor
  # Self-rescheduling recovery tick, shared by every queueing backend's
  # sweeper job class. Each run sweeps both the top-level reactor sweeper and
  # the map sweeper, then schedules the next tick — a perpetual chain the
  # host kicks once via `RubyReactor.start_sweeper!`.
  #
  # super_fetch safety. Sidekiq Enterprise `super_fetch` reliably re-runs a job
  # whose worker died mid-execution. For a self-rescheduling chain that is a
  # hazard: a tick can crash AFTER enqueuing its successor but BEFORE acking, so
  # super_fetch recovers the crashed tick *alongside* the successor it already
  # scheduled — the chain forks and then doubles every interval. We therefore do
  # NOT rely on "exactly one job exists". The next tick is claimed by a
  # per-time-window lock: every duplicate computes the SAME target window and
  # only one wins the claim, so recovered/duplicated ticks collapse back to a
  # single chain. The claim lock is never released — it simply expires — so no
  # delete can race two duplicates into both winning.
  module SweeperJob
    def self.included(base)
      base.extend(ClassMethods)
    end

    def perform
      config = RubyReactor.configuration
      return unless config.sweeper_enabled

      run_sweeps(config)
    ensure
      # Always chain forward (unless disabled), even after an error above, so a
      # single bad sweep can't kill recovery. The window lock keeps this from
      # forking under super_fetch.
      self.class.schedule_next if RubyReactor.configuration.sweeper_enabled
    end

    def run_sweeps(config)
      RubyReactor::Sweeper.run_once(limit: config.sweeper_limit)
      RubyReactor::Map::Sweeper.run_once(limit: config.sweeper_limit)
    rescue StandardError => e
      config.logger.error("RubyReactor sweeper sweep failed: #{e.class}: #{e.message}")
    end

    module ClassMethods
      # Enqueue the next tick for the upcoming time window, claiming that window
      # so concurrent/duplicate/recovered ticks produce exactly one successor.
      # Idempotent: also safe to call from `start_sweeper!` on every process boot.
      def schedule_next
        interval = RubyReactor.configuration.sweeper_interval
        window = (Time.now.to_i / interval) + 1

        lock = RubyReactor::Lock.new(
          "sweeper:window:#{window}",
          owner: SecureRandom.uuid,
          ttl: interval * 2, # outlive the window; expires on its own (never released)
          wait: 0,
          auto_extend: false
        )
        lock.acquire # raises AcquisitionError if this window is already claimed

        delay = (window * interval) - Time.now.to_i
        perform_in([delay, 1].max)
      rescue RubyReactor::Lock::AcquisitionError
        # Another tick already scheduled this window — collapse the duplicate.
        nil
      end
    end
  end
end
