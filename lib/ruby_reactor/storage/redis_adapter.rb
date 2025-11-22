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
        # Use JSON.SET for efficient storage and retrieval
        @redis.call("JSON.SET", key, ".", serialized_context.to_json)
        @redis.expire(key, 86_400) # 24h TTL
      end

      def retrieve_context(context_id, reactor_class_name)
        key = context_key(context_id, reactor_class_name)
        json = @redis.call("JSON.GET", key)
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
        @redis.set(key, count)
        @redis.expire(key, 86_400)
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

      def subscribe(channel, &block)
        @redis.subscribe(channel, &block)
      end

      def publish(channel, message)
        @redis.publish(channel, message)
      end

      def expire(key, seconds)
        @redis.expire(key, seconds)
      end

      private

      def context_key(context_id, reactor_class_name)
        "reactor:#{reactor_class_name}:context:#{context_id}"
      end

      def map_results_key(map_id, reactor_class_name)
        "reactor:#{reactor_class_name}:map:#{map_id}:results"
      end

      def map_counter_key(map_id, reactor_class_name)
        "reactor:#{reactor_class_name}:map:#{map_id}:counter"
      end
    end
  end
end
