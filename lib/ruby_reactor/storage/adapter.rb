# frozen_string_literal: true

module RubyReactor
  module Storage
    class Adapter
      def store_context(context_id, serialized_context, reactor_class_name)
        raise NotImplementedError
      end

      def retrieve_context(context_id, reactor_class_name)
        raise NotImplementedError
      end

      def store_map_result(map_id, index, serialized_result, reactor_class_name, strict_ordering: true)
        raise NotImplementedError
      end

      def retrieve_map_results(map_id, reactor_class_name, strict_ordering: true)
        raise NotImplementedError
      end

      def set_map_counter(map_id, count, reactor_class_name)
        raise NotImplementedError
      end

      def increment_map_counter(map_id, reactor_class_name)
        raise NotImplementedError
      end

      def decrement_map_counter(map_id, reactor_class_name)
        raise NotImplementedError
      end

      def subscribe(channel, &block)
        raise NotImplementedError
      end

      def publish(channel, message)
        raise NotImplementedError
      end

      def expire(key, seconds)
        raise NotImplementedError
      end
    end
  end
end
