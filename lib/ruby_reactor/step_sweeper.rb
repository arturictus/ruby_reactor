# frozen_string_literal: true

module RubyReactor
  # Re-dispatches `async_step` units whose job was lost.
  #
  # An `async_step` is the one dispatched unit with no context of its own, so
  # neither Sweeper (top-level contexts) nor Map::Sweeper (map elements) can see
  # it. All it leaves behind is a Step Result Record stuck at `dispatched`, and
  # because that record is also the re-attach marker, `already_dispatched?`
  # actively refuses to dispatch again — so without this sweep a lost unit strands
  # its parent forever, re-parking on every recovery of the parent itself.
  #
  # Liveness is the `async_step:` lock StepWorker holds for the life of the unit,
  # mirroring how Sweeper reads `async:` and Map::Sweeper reads `map_element:`. A
  # duplicate that races a live worker loses that lock and drops itself, so a
  # mis-judged unit re-runs its body at most once.
  class StepSweeper
    DEFAULT_LIMIT = 1000

    # The re-dispatch arguments, which the record carries verbatim because its
    # key names the reactor that owns the step rather than the root the worker
    # must load. Records written before recovery existed lack them and are skipped.
    DISPATCH_KEYS = %w[root_context_id reactor_class_name step_context_id step_name].freeze

    def self.run_once(limit: DEFAULT_LIMIT)
      new.run_once(limit: limit)
    end

    def initialize(storage: nil, async_router: nil, logger: nil)
      @storage = storage || RubyReactor.configuration.storage_adapter
      @async_router = async_router || RubyReactor.configuration.async_router
      @logger = logger || RubyReactor.configuration.logger
    end

    # Scans stored Step Result Records and re-dispatches the dispatched-but-dead
    # ones. Returns the number re-dispatched.
    def run_once(limit: DEFAULT_LIMIT)
      redispatched = 0

      @storage.scan_step_results(count: limit).each do |record|
        next unless record["status"] == "dispatched"

        arguments = dispatch_arguments(record)
        next unless arguments
        next if parked?(record)
        next if live?(arguments)

        redispatch(record, arguments)
        redispatched += 1
      rescue StandardError => e
        # One bad record must not abort the whole sweep.
        @logger.warn("RubyReactor::StepSweeper failed to re-dispatch #{record["step_name"]}: #{e.class}: #{e.message}")
      end

      redispatched
    end

    private

    # A swept park must not restart its contention counter: rebuilt from the
    # record alone, a zeroed payload would let `lock_snooze_max_attempts`
    # never bite. `perform_step_in(0, ...)` is the only re-dispatch that
    # carries the count.
    def redispatch(record, arguments)
      attempts = record["contention_attempts"].to_i
      return @async_router.perform_step_async(**arguments) unless attempts.positive?

      @async_router.perform_step_in(0, **arguments, contention_attempts: attempts)
    end

    def dispatch_arguments(record)
      values = record.values_at(*DISPATCH_KEYS)
      return nil if values.any?(&:nil?)

      DISPATCH_KEYS.map(&:to_sym).zip(values).to_h
    end

    # A unit parked on step-level contention (StepWorker#handle_contention)
    # released its liveness lock on purpose and has a redelivery already
    # scheduled. It looks exactly like a lost unit, so without this the sweep
    # would dispatch a duplicate that runs the body a second time once the
    # redelivery fires. Past the stamped window it is fair game again.
    def parked?(record)
      parked_until = record["parked_until"]
      return false unless parked_until

      Time.iso8601(parked_until) > Time.now
    rescue ArgumentError, TypeError
      false
    end

    def live?(arguments)
      @storage.lock_held?(
        RubyReactor.async_step_lock_key(arguments[:step_context_id], arguments[:step_name])
      )
    end
  end
end
