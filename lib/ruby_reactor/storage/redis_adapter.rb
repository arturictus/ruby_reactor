# frozen_string_literal: true

require "redis"
require "json"

module RubyReactor
  module Storage
    class RedisAdapter < Adapter
      def initialize(redis_config)
        super()
        @redis = Redis.new(redis_config)
      end

      def store_context(context_id, serialized_context, reactor_class_name)
        key = context_key(context_id, reactor_class_name)
        # Use standard SET for compatibility (ReJSON not strictly required for full docs)
        @redis.set(key, serialized_context, ex: 86_400) # 24h TTL
      end

      def retrieve_context(context_id, reactor_class_name)
        key = context_key(context_id, reactor_class_name)
        json = @redis.get(key)
        return nil unless json

        JSON.parse(json)
      end

      def store_map_result(map_id, index, serialized_result, reactor_class_name, strict_ordering: true)
        key = map_results_key(map_id, reactor_class_name)

        if strict_ordering
          # Use Hash for strict ordering by index
          # HSET key index serialized_result
          @redis.hset(key, index.to_s, serialized_result.to_json)
        else
          # Loose ordering: just push to list
          @redis.rpush(key, serialized_result.to_json)
        end

        @redis.expire(key, 86_400)
      end

      def retrieve_map_results(map_id, reactor_class_name, strict_ordering: true)
        key = map_results_key(map_id, reactor_class_name)

        if strict_ordering
          results = @redis.hgetall(key)
          # Sort by index (key)
          results.keys.sort_by(&:to_i).map { |k| JSON.parse(results[k]) }
        else
          results = @redis.lrange(key, 0, -1)
          results.map { |r| JSON.parse(r) }
        end
      end

      def set_map_counter(map_id, count, reactor_class_name)
        key = map_counter_key(map_id, reactor_class_name)
        @redis.set(key, count, ex: 86_400)
      end

      def initialize_map_operation(map_id, count, parent_reactor_class_name, reactor_class_info:, strict_ordering: true)
        # Ensure counter is set
        set_map_counter(map_id, count, parent_reactor_class_name)

        # Store metadata
        key = "reactor:#{parent_reactor_class_name}:map:#{map_id}:metadata"
        metadata = {
          count: count,
          strict_ordering: strict_ordering,
          reactor_class_info: reactor_class_info,
          created_at: Time.now.to_i
        }
        @redis.set(key, metadata.to_json, ex: 86_400)
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
        @redis.expire(key, 86_400)
      end

      def decrement_map_counter(map_id, reactor_class_name)
        key = map_counter_key(map_id, reactor_class_name)
        @redis.decr(key)
      end

      def set_last_queued_index(map_id, index, reactor_class_name)
        key = map_last_queued_index_key(map_id, reactor_class_name)
        @redis.set(key, index, ex: 86_400)
      end

      def increment_last_queued_index(map_id, reactor_class_name)
        key = map_last_queued_index_key(map_id, reactor_class_name)
        @redis.incr(key)
      end

      def store_correlation_id(correlation_id, context_id, reactor_class_name)
        key = correlation_id_key(correlation_id, reactor_class_name)
        # Store mapping correlation_id -> context_id
        success = @redis.set(key, context_id, nx: true, ex: 86_400) # 24h TTL, fail if exists

        raise Error::ValidationError, "Correlation ID '#{correlation_id}' already exists" unless success
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

      def subscribe(channel, &block)
        @redis.subscribe(channel, &block)
      end

      def publish(channel, message)
        @redis.publish(channel, message)
      end

      def expire(key, seconds)
        @redis.expire(key, seconds)
      end

      # New methods for API
      def scan_reactors(pattern: "reactor:*:context:*", count: 50)
        # Use SCAN to find keys matching the pattern
        results = []
        batch_keys = []

        # scan_each yields keys. We buffer them to use MGET efficiently.
        # We request a batch size from Redis (count: 100) to reduce roundtrips.
        @redis.scan_each(match: pattern, count: 100) do |key|
          batch_keys << key

          # specific batch size for MGET processing
          if batch_keys.size >= 50
            results.concat(fetch_and_filter_reactors(batch_keys))
            batch_keys = []

            # Stop if we have enough results
            return results.take(count) if results.size >= count
          end
        end

        # Process remaining keys
        results.concat(fetch_and_filter_reactors(batch_keys)) if batch_keys.any?

        results.take(count)
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

      def determine_status(data)
        return data["status"] if data["status"] && %w[failed paused completed running].include?(data["status"])
        return "cancelled" if data["cancelled"]
        return "failed" if data["retry_count"] && data["retry_count"] > 0 && !data["current_step"].nil? # Heuristic
        return "completed" unless data["current_step"]

        "running"
      end

      def store_map_element_context_id(map_id, context_id, reactor_class_name)
        key = map_element_contexts_key(map_id, reactor_class_name)
        @redis.rpush(key, context_id)
        @redis.expire(key, 86_400)
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
        @redis.set(key, context_id, nx: true, ex: 86_400)
      end

      def retrieve_map_failed_context_id(map_id, reactor_class_name)
        key = map_failed_context_key(map_id, reactor_class_name)
        @redis.get(key)
      end

      private

      def fetch_and_filter_reactors(keys)
        return [] if keys.empty?

        json_results = @redis.mget(*keys)

        json_results.compact.map do |json|
          data = JSON.parse(json)
          next if data["parent_context_id"] # Skip nested reactors

          {
            id: data["context_id"],
            class: data["reactor_class"],
            status: determine_status(data),
            created_at: data["started_at"],
            failure: data["failure_reason"]
          }
        end.compact
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
