# frozen_string_literal: true

require "redis"
require "json"
require "digest"

module RubyReactor
  module Storage
    class RedisAdapter < Adapter
      include RedisLocking
      include RedisOrderedLocking
      include RedisStepResults
      include RedisPubSub
      include RedisReactorScan
      include RedisMapRollback

      def initialize(redis_config)
        super()
        @redis_config = redis_config
        @redis = Redis.new(redis_config)
      end

      def store_context(context_id, serialized_context, reactor_class_name)
        key = context_key(context_id, reactor_class_name)
        # Use standard SET for compatibility (ReJSON not strictly required for full docs).
        # TTL is re-stamped on every write so long-running / snoozed contexts
        # never expire mid-flight (Phase 4).
        @redis.set(key, serialized_context, ex: durability_ttl)
      end

      def retrieve_context(context_id, reactor_class_name)
        key = context_key(context_id, reactor_class_name)
        json = @redis.get(key)
        return nil unless json

        JSON.parse(json)
      end

      # Durable map storage is ALWAYS index-keyed (HSET), regardless of
      # strict_ordering. The index->slot mapping makes completion recoverable
      # (missing = (0...count) - HKEYS) and re-dispatch idempotent (re-running
      # index i overwrites slot i, never duplicates). strict_ordering is now only
      # a read-order convenience, not a storage-layout switch (Phase 5).
      # rubocop:disable Lint/UnusedMethodArgument
      def store_map_result(map_id, index, serialized_result, reactor_class_name, strict_ordering: true)
        key = map_results_key(map_id, reactor_class_name)
        @redis.hset(key, index.to_s, serialized_result.to_json)
        @redis.expire(key, durability_ttl)
      end

      def retrieve_map_results(map_id, reactor_class_name, strict_ordering: true)
        # rubocop:enable Lint/UnusedMethodArgument
        key = map_results_key(map_id, reactor_class_name)
        results = @redis.hgetall(key)
        # Index-keyed for both modes; sort by index so reads are deterministic.
        results.keys.sort_by(&:to_i).map { |k| JSON.parse(results[k]) }
      end

      # Indices that have NO stored result yet: the authoritative, idempotent
      # signal for what the map sweeper must (re)dispatch.
      def missing_map_indices(map_id, count, reactor_class_name)
        key = map_results_key(map_id, reactor_class_name)
        present = @redis.hkeys(key).map(&:to_i)
        (0...count).to_a - present
      end

      def set_map_counter(map_id, count, reactor_class_name)
        key = map_counter_key(map_id, reactor_class_name)
        @redis.set(key, count, ex: durability_ttl)
      end

      # rubocop:disable Metrics/ParameterLists
      def initialize_map_operation(map_id, count, parent_reactor_class_name, reactor_class_info:, strict_ordering: true,
                                   parent_context_id: nil, step_name: nil, parent_is_map_element: false,
                                   outer_map_id: nil, outer_index: nil, owner_context_id: nil,
                                   owner_reactor_class_name: nil, batch_size: nil, atomic: nil)
        # Ensure counter is set
        set_map_counter(map_id, count, parent_reactor_class_name)

        # Store metadata. parent_context_id/step_name let the map sweeper recover
        # without re-deriving the map_id (which is brittle to split on ':'). The
        # nested-map fields (parent_is_map_element + outer_map_id/outer_index)
        # record which liveness lock the parent actually holds (N1): a nested
        # map's parent is itself a map element running under a `map_element:` lock,
        # not an `async:` lock. The owner is the top-level run the collector
        # resumes (009 R-03); `batch_size` and `atomic` let a re-dispatched
        # element keep both (R-10).
        key = "reactor:#{parent_reactor_class_name}:map:#{map_id}:metadata"
        metadata = {
          map_id: map_id,
          count: count,
          strict_ordering: strict_ordering,
          reactor_class_info: reactor_class_info,
          parent_context_id: parent_context_id,
          parent_reactor_class_name: parent_reactor_class_name,
          step_name: step_name,
          parent_is_map_element: parent_is_map_element,
          outer_map_id: outer_map_id,
          outer_index: outer_index,
          owner_context_id: owner_context_id,
          owner_reactor_class_name: owner_reactor_class_name,
          batch_size: batch_size,
          atomic: atomic,
          created_at: Time.now.to_i
        }
        @redis.set(key, metadata.to_json, ex: durability_ttl)
      end
      # rubocop:enable Metrics/ParameterLists

      # Claimed once, by the collector that found the map settled: only that
      # one enqueues the owner's Worker (009 DM §3).
      def claim_map_owner_signal(map_id, reactor_class_name) # rubocop:disable Naming/PredicateMethod
        !!@redis.set("reactor:#{reactor_class_name}:map:#{map_id}:owner_signalled", "1", nx: true, ex: durability_ttl)
      end

      # Enumerate active map operations for the map sweeper (Phase 5d). Returns
      # the parsed metadata hash for each (includes map_id, count,
      # parent_context_id, step_name, parent_reactor_class_name, and the nested-map
      # lock fields). Bounded by `count` to keep a sweep cheap.
      def scan_maps(count: 1000)
        results = []
        @redis.scan_each(match: "reactor:*:map:*:metadata", count: 100) do |key|
          next if key.end_with?(":rollback:metadata") # a hash, listed by scan_map_rollbacks

          json = @redis.get(key)
          next unless json

          results << JSON.parse(json)
          return results if results.size >= count
        end
        results
      end

      def retrieve_map_metadata(map_id, reactor_class_name)
        key = "reactor:#{reactor_class_name}:map:#{map_id}:metadata"
        json = @redis.get(key)
        return nil unless json

        JSON.parse(json)
      end

      def increment_map_counter(map_id, reactor_class_name)
        key = map_counter_key(map_id, reactor_class_name)
        @redis.incr(key)
        @redis.expire(key, durability_ttl)
      end

      def decrement_map_counter(map_id, reactor_class_name)
        key = map_counter_key(map_id, reactor_class_name)
        @redis.decr(key)
      end

      # Settles `amount` indices at once (a fail-fast dispatcher claiming the
      # ones it never dispatched). Returns the count left.
      def decrement_map_counter_by(map_id, amount, reactor_class_name)
        key = map_counter_key(map_id, reactor_class_name)
        left = @redis.decrby(key, amount)
        @redis.expire(key, durability_ttl)
        left
      end

      def set_last_queued_index(map_id, index, reactor_class_name)
        key = map_last_queued_index_key(map_id, reactor_class_name)
        @redis.set(key, index, ex: durability_ttl)
      end

      def increment_last_queued_index(map_id, reactor_class_name)
        key = map_last_queued_index_key(map_id, reactor_class_name)
        @redis.incr(key)
      end

      def store_correlation_id(correlation_id, context_id, reactor_class_name)
        key = correlation_id_key(correlation_id, reactor_class_name)
        # Store mapping correlation_id -> context_id
        # Try to set if not exists
        success = @redis.set(key, context_id, nx: true, ex: durability_ttl)

        return if success

        # If it exists, check if it's the same context_id
        existing_context_id = @redis.get(key)

        if existing_context_id == context_id
          # Refresh TTL
          @redis.expire(key, durability_ttl)
          return
        end

        raise Error::ValidationError, "Correlation ID '#{correlation_id}' already exists"
      end

      def retrieve_context_id_by_correlation_id(correlation_id, reactor_class_name)
        key = correlation_id_key(correlation_id, reactor_class_name)
        @redis.get(key)
      end

      def delete_correlation_id(correlation_id, reactor_class_name)
        key = correlation_id_key(correlation_id, reactor_class_name)
        @redis.del(key)
      end

      def delete_context(context_id, reactor_class_name)
        key = context_key(context_id, reactor_class_name)
        @redis.del(key)
      end

      def expire(key, seconds)
        @redis.expire(key, seconds)
      end

      def find_context_by_id(context_id)
        # We don't know the reactor class, so we search for the ID
        pattern = "reactor:*:context:#{context_id}"
        keys = []
        @redis.scan_each(match: pattern, count: 1) do |key|
          keys << key
          break
        end
        return nil if keys.empty?

        key = keys.first
        json = @redis.get(key)
        return nil unless json

        JSON.parse(json)
      end

      def store_map_element_context_id(map_id, context_id, reactor_class_name)
        key = map_element_contexts_key(map_id, reactor_class_name)
        @redis.rpush(key, context_id)
        @redis.expire(key, durability_ttl)
      end

      def retrieve_map_element_context_ids(map_id, reactor_class_name)
        key = map_element_contexts_key(map_id, reactor_class_name)
        @redis.lrange(key, 0, -1)
      end

      def retrieve_map_element_context_id(map_id, reactor_class_name, index: -1)
        key = map_element_contexts_key(map_id, reactor_class_name)
        @redis.lindex(key, index)
      end

      def store_map_failed_context_id(map_id, context_id, reactor_class_name)
        key = map_failed_context_key(map_id, reactor_class_name)
        # Only store the first failure (nx: true)
        @redis.set(key, context_id, nx: true, ex: durability_ttl)
      end

      def retrieve_map_failed_context_id(map_id, reactor_class_name)
        key = map_failed_context_key(map_id, reactor_class_name)
        @redis.get(key)
      end

      def set_map_offset(map_id, offset, reactor_class_name)
        key = map_offset_key(map_id, reactor_class_name)
        @redis.set(key, offset, ex: durability_ttl)
      end

      def set_map_offset_if_not_exists(map_id, offset, reactor_class_name)
        key = map_offset_key(map_id, reactor_class_name)
        @redis.set(key, offset, nx: true, ex: durability_ttl)
      end

      def retrieve_map_offset(map_id, reactor_class_name)
        key = map_offset_key(map_id, reactor_class_name)
        @redis.get(key)
      end

      def increment_map_offset(map_id, increment, reactor_class_name)
        key = map_offset_key(map_id, reactor_class_name)
        @redis.incrby(key, increment)
      end

      # rubocop:disable Lint/UnusedMethodArgument
      def retrieve_map_results_batch(map_id, reactor_class_name, offset:, limit:, strict_ordering: true)
        # Always index-keyed now (Phase 5): HMGET the contiguous index window.
        key = map_results_key(map_id, reactor_class_name)
        fields = (offset...(offset + limit)).map(&:to_s)
        results = @redis.hmget(key, *fields)
        results.compact.map { |r| JSON.parse(r) }
      end
      # rubocop:enable Lint/UnusedMethodArgument

      def count_map_results(map_id, reactor_class_name)
        key = map_results_key(map_id, reactor_class_name)
        @redis.hlen(key)
      end

      # Result slots at `indexes`, aligned with them: nil where a slot is
      # missing (expired), else the stored value, JSON-parsed (010 R-13).
      def retrieve_map_result_slots(map_id, reactor_class_name, indexes)
        return [] if indexes.empty?

        @redis.hmget(map_results_key(map_id, reactor_class_name), *indexes.map(&:to_s)).map do |raw|
          raw && JSON.parse(raw)
        end
      end

      # A resume's claim on one interrupt (010 DM §2): the first `SET NX` wins,
      # and the value holds the payload until the run's lock owner applies it.
      # Never deleted; it expires with the run and stays the dedupe marker.
      def claim_interrupt_resume(context_id, reactor_class_name, step_name, serialized_payload) # rubocop:disable Naming/PredicateMethod
        !!@redis.set(interrupt_resume_key(context_id, reactor_class_name, step_name), serialized_payload,
                     nx: true, ex: durability_ttl)
      end

      # `{ "step" => serialized_payload }` for the claimed ones among `step_names`.
      def retrieve_interrupt_resumes(context_id, reactor_class_name, step_names)
        names = Array(step_names).map(&:to_s)
        return {} if names.empty?

        values = @redis.mget(*names.map { |name| interrupt_resume_key(context_id, reactor_class_name, name) })
        names.zip(values).to_h.compact
      end

      # Run-level idempotency (011 R-15): the first caller claims `key` for its
      # run; later callers get that run's id back. Kept for `context_ttl`, the
      # same horizon as the run it points at.
      def claim_idempotency_key(key, context_id, reactor_class_name)
        redis_key = "reactor:#{reactor_class_name}:idempotency:#{Digest::SHA256.hexdigest(key.to_s)}"
        return nil if @redis.set(redis_key, context_id, nx: true, ex: durability_ttl)

        @redis.get(redis_key)
      end

      # Invalid resume payloads counted per interrupt (010 DM §3), kept out of
      # the context blob so counting never writes the run.
      def increment_interrupt_attempts(context_id, reactor_class_name, step_name)
        key = "#{context_key(context_id, reactor_class_name)}:resume_attempts:#{step_name}"
        count, = @redis.multi do |tx|
          tx.incr(key)
          tx.expire(key, durability_ttl)
        end
        count
      end

      private

      # Single source of truth for the retention window of all durability-bearing
      # state (context blob, map results/counters/metadata/offsets, correlation
      # ids). Map state is load-bearing for resume exactly like the context, so it
      # must share the context's configurable TTL — a shorter map TTL would expire
      # map results mid-flight and break recovery. Re-stamped on every write.
      def durability_ttl
        RubyReactor.configuration.context_ttl
      end

      def interrupt_resume_key(context_id, reactor_class_name, step_name)
        "#{context_key(context_id, reactor_class_name)}:resume:#{step_name}"
      end

      def context_key(context_id, reactor_class_name)
        "reactor:#{reactor_class_name}:context:#{context_id}"
      end

      def map_results_key(map_id, reactor_class_name)
        "reactor:#{reactor_class_name}:map:#{map_id}:results"
      end

      def map_counter_key(map_id, reactor_class_name)
        "reactor:#{reactor_class_name}:map:#{map_id}:counter"
      end

      def map_last_queued_index_key(map_id, reactor_class_name)
        "reactor:#{reactor_class_name}:map:#{map_id}:last_queued_index"
      end

      def map_offset_key(map_id, reactor_class_name)
        "reactor:#{reactor_class_name}:map:#{map_id}:offset"
      end

      def correlation_id_key(correlation_id, reactor_class_name)
        "reactor:#{reactor_class_name}:correlation:#{correlation_id}"
      end

      def map_element_contexts_key(map_id, reactor_class_name)
        "reactor:#{reactor_class_name}:map:#{map_id}:element_contexts"
      end

      def map_failed_context_key(map_id, reactor_class_name)
        "reactor:#{reactor_class_name}:map:#{map_id}:failed_context_id"
      end
    end
  end
end
