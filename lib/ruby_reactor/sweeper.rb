# frozen_string_literal: true

module RubyReactor
  # Re-enqueues non-terminal top-level reactor contexts whose worker died.
  #
  # The per-context liveness lock (`async:<id>`, Phase 1) is the signal: a live
  # worker holds and auto-extends it, so its ABSENCE on a context still marked
  # `running` means the worker crashed without finishing. The sweeper re-enqueues
  # such contexts by id (identity-only payload, Phase 2).
  #
  # `run_once` is pure and idempotent — call it periodically; the cadence is the
  # host's to wire (sidekiq-cron, sidekiq-scheduler, a self-rescheduling worker,
  # or external cron). The interval bounds recovery latency. No scheduling
  # dependency is added to the gem.
  #
  # Safety depends on Phase 1: if a context is mis-judged dead (GC pause, liveness
  # race) and re-enqueued while its worker is actually alive, the duplicate hits
  # the live lock -> ContextLockContention -> uncapped snooze -> no double run.
  #
  # Map fan-out (element/collector jobs) is NOT covered here — those contexts
  # carry parent_context_id and scan_reactors filters them out (F6). The map
  # sweeper (Phase 5) owns them.
  class Sweeper
    # Default upper bound on contexts inspected per sweep. scan_reactors caps its
    # result at this count; a host with more in-flight reactors than this should
    # raise it (or sweep more frequently).
    DEFAULT_LIMIT = 1000

    def self.run_once(limit: DEFAULT_LIMIT)
      new.run_once(limit: limit)
    end

    def initialize(storage: nil, async_router: nil, logger: nil)
      @storage = storage || RubyReactor.configuration.storage_adapter
      @async_router = async_router || RubyReactor.configuration.async_router
      @logger = logger || RubyReactor.configuration.logger
    end

    # Scans stored top-level reactors and re-enqueues the running-but-unlocked
    # ones. Returns the number of contexts re-enqueued.
    def run_once(limit: DEFAULT_LIMIT)
      reenqueued = 0

      @storage.scan_reactors(count: limit).each do |reactor|
        next unless reactor[:status] == "running" # non-terminal only
        next if @storage.lock_held?("async:#{reactor[:id]}") # worker alive -> leave alone

        @async_router.perform_async(reactor[:id], reactor[:class])
        reenqueued += 1
      rescue StandardError => e
        # One bad record must not abort the whole sweep.
        @logger.warn("RubyReactor::Sweeper failed to re-enqueue #{reactor[:id]}: #{e.class}: #{e.message}")
      end

      reenqueued
    end
  end
end
