# frozen_string_literal: true

module RubyReactor
  module Storage
    # Where a run was last dispatched and, while a job is still on its way,
    # since when (011 R-04, data-model §3.1). Outside the context blob on
    # purpose: the sweeper, the map collector and a busy `continue` dispatch a
    # run they do not own, and only the owning execution writes the blob.
    #
    # A Redis hash next to the context key: `MGET` in the reactor listings
    # returns nil for it, so it never shows up as a reactor.
    module RedisRunDispatch
      def store_run_dispatch(context_id, reactor_class_name, queue)
        key = run_dispatch_key(context_id, reactor_class_name)
        @redis.multi do |tx|
          tx.hset(key, "queue", queue.to_s, "since", Time.now.utc.iso8601)
          tx.expire(key, durability_ttl)
        end
      end

      def retrieve_run_dispatch(context_id, reactor_class_name)
        record = @redis.hgetall(run_dispatch_key(context_id, reactor_class_name))
        record.empty? ? nil : record
      end

      # A worker picked the run up: it is no longer waiting. Only a job on the
      # recorded queue clears it, so a stray duplicate on another queue never
      # hides a dispatch still on its way.
      # ponytail: non-atomic compare-and-clear; observability only, last writer wins.
      def clear_run_dispatch_wait(context_id, reactor_class_name, queue)
        key = run_dispatch_key(context_id, reactor_class_name)
        @redis.hset(key, "since", "") if @redis.hget(key, "queue") == queue.to_s
      end

      private

      def run_dispatch_key(context_id, reactor_class_name)
        "#{context_key(context_id, reactor_class_name)}:dispatch"
      end
    end
  end
end
