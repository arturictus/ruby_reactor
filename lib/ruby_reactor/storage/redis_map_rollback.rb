# frozen_string_literal: true

module RubyReactor
  module Storage
    # The records of one fan-out map's distributed rollback (009 DM §5), under
    # `reactor:<P>:map:<map_id>:rollback:…`. Element rollback jobs write only
    # these and their own element context, never a reactor context (I-1).
    #
    # Positions count from the tail of the element-context index, anchored at
    # the `total` the rollback started with, so an id a late duplicate appends
    # afterwards never shifts them.
    module RedisMapRollback
      # Creates the metadata only if no rollback of this map exists (I-3).
      START_ROLLBACK_SCRIPT = <<~LUA
        if redis.call('EXISTS', KEYS[1]) == 1 then return 0 end
        redis.call('HSET', KEYS[1], unpack(ARGV, 2))
        redis.call('EXPIRE', KEYS[1], ARGV[1])
        return 1
      LUA

      FAILED_OUTCOMES = %w[failed element_in_flight context_unavailable].freeze

      def count_map_element_context_ids(map_id, reactor_class_name)
        @redis.llen(map_element_contexts_key(map_id, reactor_class_name))
      end

      # Ids at tail positions `position...position + count`, in tail order.
      def retrieve_map_element_context_ids_from_tail(map_id, reactor_class_name, position, count, total:)
        stop = total - 1 - position
        return [] if stop.negative?

        start = [total - position - count, 0].max
        @redis.lrange(map_element_contexts_key(map_id, reactor_class_name), start, stop).reverse
      end

      # `[created, metadata]`: a second start finds the first one's records.
      def start_map_rollback(map_id, reactor_class_name, **meta)
        fields = meta.merge(map_id: map_id, parent_reactor_class_name: reactor_class_name, started_at: Time.now.to_i)
        argv = fields.flat_map { |k, v| [k.to_s, JSON.generate(v)] }
        created = @redis.eval(START_ROLLBACK_SCRIPT, keys: [map_rollback_key(map_id, reactor_class_name, :metadata)],
                                                     argv: [durability_ttl, *argv])
        [created == 1, retrieve_map_rollback_metadata(map_id, reactor_class_name)]
      end

      def retrieve_map_rollback_metadata(map_id, reactor_class_name)
        parse_rollback_metadata(@redis.hgetall(map_rollback_key(map_id, reactor_class_name, :metadata)))
      end

      # Claims the next `count` positions (R-02), clipped to the total.
      def claim_map_rollback_positions(map_id, reactor_class_name, count)
        key = map_rollback_key(map_id, reactor_class_name, :offset)
        stop = @redis.incrby(key, count)
        @redis.expire(key, durability_ttl)
        total = retrieve_map_rollback_metadata(map_id, reactor_class_name)&.fetch("total", 0).to_i
        (stop - count)...[stop, total].min
      end

      def retrieve_map_rollback_offset(map_id, reactor_class_name)
        @redis.get(map_rollback_key(map_id, reactor_class_name, :offset)).to_i
      end

      # The first outcome for a position wins: a duplicate delivery, which
      # finds the element already undone, must not replace a `failed` outcome
      # with its own `undone`. Returns whether this call stored it.
      def store_map_rollback_outcome(map_id, reactor_class_name, position, outcome) # rubocop:disable Naming/PredicateMethod
        results = map_rollback_key(map_id, reactor_class_name, :results)
        indexes = map_rollback_key(map_id, reactor_class_name, :indexes)
        index = outcome["index"] || outcome[:index]
        stored, = @redis.multi do |tx|
          tx.hsetnx(results, position.to_s, JSON.generate(outcome))
          tx.expire(results, durability_ttl)
          tx.sadd(indexes, index.to_s) unless index.nil?
          tx.expire(indexes, durability_ttl)
        end
        [true, 1].include?(stored)
      end

      def count_map_rollback_outcomes(map_id, reactor_class_name)
        @redis.hlen(map_rollback_key(map_id, reactor_class_name, :results))
      end

      def stored_map_rollback_positions(map_id, reactor_class_name)
        @redis.hkeys(map_rollback_key(map_id, reactor_class_name, :results)).map(&:to_i)
      end

      def map_rollback_outcome_stored?(map_id, reactor_class_name, position)
        @redis.hexists(map_rollback_key(map_id, reactor_class_name, :results), position.to_s)
      end

      # Yields `position, outcome` in bounded reads.
      def each_map_rollback_outcome(map_id, reactor_class_name)
        @redis.hscan_each(map_rollback_key(map_id, reactor_class_name, :results), count: 500) do |position, json|
          yield position.to_i, JSON.parse(json)
        end
      end

      # One boolean per index: whether a rollback job saw that element (R-09).
      def map_rollback_indexes_seen(map_id, reactor_class_name, indexes)
        key = map_rollback_key(map_id, reactor_class_name, :indexes)
        @redis.pipelined { |pipe| indexes.each { |index| pipe.sismember(key, index.to_s) } }
      end

      def mark_map_rollback_handed_off(map_id, reactor_class_name)
        @redis.set(map_rollback_key(map_id, reactor_class_name, :handed_off), "1", ex: durability_ttl)
      end

      def map_rollback_handed_off?(map_id, reactor_class_name)
        @redis.exists?(map_rollback_key(map_id, reactor_class_name, :handed_off))
      end

      def claim_map_rollback_signal(map_id, reactor_class_name) # rubocop:disable Naming/PredicateMethod
        !!@redis.set(map_rollback_key(map_id, reactor_class_name, :signalled), "1", nx: true, ex: durability_ttl)
      end

      # Progress for the dashboard (R-15), or nil when this map never rolled back.
      def map_rollback_summary(map_id, reactor_class_name)
        meta = retrieve_map_rollback_metadata(map_id, reactor_class_name)
        return nil unless meta

        failed = 0
        each_map_rollback_outcome(map_id, reactor_class_name) do |_, outcome|
          failed += 1 if FAILED_OUTCOMES.include?(outcome["outcome"])
        end
        total = meta["total"].to_i
        settled = count_map_rollback_outcomes(map_id, reactor_class_name)
        { total: total, settled: settled, outstanding: total - settled, failed: failed }
      end

      # Every started map rollback, for `Map::Sweeper` (S-5).
      def scan_map_rollbacks(count: 1000)
        results = []
        @redis.scan_each(match: "reactor:*:map:*:rollback:metadata", count: 100) do |key|
          meta = parse_rollback_metadata(@redis.hgetall(key))
          results << meta if meta
          return results if results.size >= count
        end
        results
      end

      private

      def parse_rollback_metadata(raw)
        return nil if raw.nil? || raw.empty?

        raw.transform_values { |value| JSON.parse(value) }
      end

      def map_rollback_key(map_id, reactor_class_name, suffix)
        "reactor:#{reactor_class_name}:map:#{map_id}:rollback:#{suffix}"
      end
    end
  end
end
