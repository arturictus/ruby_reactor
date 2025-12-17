module RubyReactor
  module Storage
    class RedisAdapter < Adapter
      def store_context(context_id, serialized_context, reactor_class_name)
        key = context_key(context_id, reactor_class_name)
        # Fallback to standard SET for standard Redis (no RedisJSON)
        @redis.set(key, serialized_context, ex: 86_400)
      end

      def retrieve_context(context_id, reactor_class_name)
        key = context_key(context_id, reactor_class_name)
        json = @redis.get(key)
        return nil unless json

        JSON.parse(json)
      end

      def initialize_map_operation(map_id, count, parent_reactor_class_name, reactor_class_info:, strict_ordering: true)
        set_map_counter(map_id, count, parent_reactor_class_name)

        key = "reactor:#{parent_reactor_class_name}:map:#{map_id}:metadata"
        metadata = {
          count: count,
          strict_ordering: strict_ordering,
          reactor_class_info: reactor_class_info,
          created_at: Time.now.to_i
        }
        # Fallback to standard SET
        @redis.set(key, metadata.to_json, ex: 86_400)
      end

      def retrieve_map_metadata(map_id, reactor_class_name)
        key = "reactor:#{reactor_class_name}:map:#{map_id}:metadata"
        json = @redis.get(key)
        return nil unless json

        JSON.parse(json)
      end

      def scan_reactors(pattern: "reactor:*:context:*", count: 50)
        keys = []
        @redis.scan_each(match: pattern, count: count) do |key|
          keys << key
          break if keys.size >= count
        end

        return [] if keys.empty?

        json_results = @redis.mget(*keys)

        json_results.compact.map do |json|
          data = JSON.parse(json)
          {
            id: data["context_id"],
            class: data["reactor_class"],
            status: determine_status(data),
            created_at: data["started_at"]
          }
        end
      end

      def find_context_by_id(context_id)
        # Scan for context key
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
    end
  end
end
