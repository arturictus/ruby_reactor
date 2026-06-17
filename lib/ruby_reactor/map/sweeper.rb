# frozen_string_literal: true

module RubyReactor
  module Map
    # Recovers map fan-out from a hard kill (Phase 5d). Maps are the path most
    # exposed to a lost job: one missing element result hangs the whole map and
    # its parent forever. The unifying signal is the results hash — index-keyed
    # and idempotent (HSET) — so completion is authoritative on `missing`, not on
    # the fragile counter:
    #
    #   missing = (0...count) - HKEYS(results)
    #
    # For each active map:
    #   * missing indices with NO live element lock are re-dispatched (M1/M4/M5).
    #   * if nothing is missing but the parent never resumed, the collector is
    #     re-triggered (M2) — gated so it never fires while a collector or the
    #     parent is alive, or after the parent already collected.
    #
    # `run_once` is pure and idempotent; the host wires the cadence (same contract
    # as RubyReactor::Sweeper).
    class Sweeper
      def self.run_once(limit: 1000)
        new.run_once(limit: limit)
      end

      def initialize(storage: nil, async_router: nil, logger: nil)
        @storage = storage || RubyReactor.configuration.storage_adapter
        @async_router = async_router || RubyReactor.configuration.async_router
        @logger = logger || RubyReactor.configuration.logger
      end

      # Returns { redispatched:, recollected: } counts.
      def run_once(limit: 1000)
        redispatched = 0
        recollected = 0

        @storage.scan_maps(count: limit).each do |meta|
          missing = missing_indices(meta)
          if missing.any?
            redispatched += redispatch_missing(meta, missing)
          elsif recollect?(meta)
            retrigger_collector(meta)
            recollected += 1
          end
        rescue StandardError => e
          @logger.warn("RubyReactor::Map::Sweeper failed on map #{meta["map_id"]}: #{e.class}: #{e.message}")
        end

        { redispatched: redispatched, recollected: recollected }
      end

      private

      def missing_indices(meta)
        @storage.missing_map_indices(meta["map_id"], meta["count"].to_i, meta["parent_reactor_class_name"])
      end

      def redispatch_missing(meta, missing)
        count = 0
        missing.each do |index|
          next if @storage.lock_held?("map_element:#{meta["map_id"]}:#{index}") # element alive

          RubyReactor::Map::Dispatcher.requeue_index(meta, index)
          count += 1
        end
        count
      end

      # All results are in. Re-trigger the collector only if no collector/parent is
      # alive and the parent has not already collected this step.
      def recollect?(meta)
        return false if @storage.lock_held?("map_collect:#{meta["map_id"]}")  # a collector is running
        return false if parent_live_lock?(meta)                               # parent execution alive
        return false if parent_already_collected?(meta)

        true
      end

      # N1: a nested map's parent is a map element running under a `map_element:`
      # lock, not an `async:` lock. Derive the right key from metadata.
      def parent_live_lock?(meta)
        if meta["parent_is_map_element"]
          @storage.lock_held?("map_element:#{meta["outer_map_id"]}:#{meta["outer_index"]}")
        else
          @storage.lock_held?("async:#{meta["parent_context_id"]}")
        end
      end

      def parent_already_collected?(meta)
        data = @storage.retrieve_context(meta["parent_context_id"], meta["parent_reactor_class_name"])
        return false unless data

        results = data["intermediate_results"] || {}
        status = data["status"].to_s
        results.key?(meta["step_name"].to_s) || %w[completed failed skipped].include?(status)
      end

      def retrigger_collector(meta)
        @async_router.perform_map_collection_async(
          parent_context_id: meta["parent_context_id"],
          map_id: meta["map_id"],
          parent_reactor_class_name: meta["parent_reactor_class_name"],
          step_name: meta["step_name"],
          strict_ordering: meta["strict_ordering"],
          timeout: 3600
        )
      end
    end
  end
end
