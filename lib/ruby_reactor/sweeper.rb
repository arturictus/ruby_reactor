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
  # `async_reactor` children ARE covered: each runs as its own job, so a lost
  # job strands one exactly like a top-level reactor, and a fire-and-forget
  # child has no parent left waiting to notice. They are identified by the
  # `async_dispatched` marker rather than by absence of a parent, so compose
  # children — same parent link, but run inline — are never re-enqueued.
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

      @storage.scan_reactors(count: limit, include_dispatched_children: true).each do |reactor|
        # Non-terminal only. A `rolling_back` run whose owner resume was lost
        # is re-enqueued too: unsettled, it simply hands off again (009 S-5).
        next unless %w[running rolling_back].include?(reactor[:status])
        next if @storage.lock_held?("async:#{reactor[:id]}") # worker alive -> leave alone

        log_waiting(reactor)
        Queues.enqueue_run(reactor[:id], reactor[:class], router: @async_router)
        reenqueued += 1
      rescue StandardError => e
        # One bad record must not abort the whole sweep.
        @logger.warn("RubyReactor::Sweeper failed to re-enqueue #{reactor[:id]}: #{e.class}: #{e.message}")
      end

      reenqueued
    end

    private

    # A run whose dispatch is still pending: its job may only be waiting in a
    # queue with no free worker (011 FR-020). Re-enqueued all the same — the
    # duplicate exits once a worker gets to it — but said once per sweep.
    def log_waiting(reactor)
      record = @storage.retrieve_run_dispatch(reactor[:id], reactor[:class])
      return if record.nil? || record["since"].to_s.empty?

      @logger.info("event=ruby_reactor.queue.waiting reactor=#{reactor[:class].inspect} " \
                   "execution_id=#{reactor[:id].inspect} queue=#{record["queue"].inspect} " \
                   "since=#{record["since"].inspect} source=\"sweeper\"")
    end
  end
end
