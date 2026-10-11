# frozen_string_literal: true

require "digest"

module RubyReactor
  module Storage
    # Run-level idempotency keys (011 R-15): the first caller claims `key` for
    # its run; later callers get that run's id back. Kept for `context_ttl`,
    # the same horizon as the run it points at.
    # Contract names have no `?` (see RedisLocking).
    # rubocop:disable Naming/PredicateMethod
    module RedisIdempotency
      # Compare-and-delete / compare-and-set on the claimed run id, so only the
      # holder's own run can release a claim, or a caller that saw it dead can
      # take it over (review F1).
      RELEASE_SCRIPT = <<~LUA
        if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) end
        return 0
      LUA

      RECLAIM_SCRIPT = <<~LUA
        if redis.call('get', KEYS[1]) ~= ARGV[1] then return 0 end
        redis.call('set', KEYS[1], ARGV[2], 'EX', ARGV[3])
        return 1
      LUA

      def claim_idempotency_key(key, context_id, reactor_class_name)
        redis_key = idempotency_key(key, reactor_class_name)
        @redis.set(redis_key, context_id, nx: true, ex: durability_ttl) ? nil : @redis.get(redis_key)
      end

      def release_idempotency_key(key, context_id, reactor_class_name)
        @redis.eval(RELEASE_SCRIPT, keys: [idempotency_key(key, reactor_class_name)], argv: [context_id]) == 1
      end

      def reclaim_idempotency_key(key, from_context_id, to_context_id, reactor_class_name)
        @redis.eval(RECLAIM_SCRIPT, keys: [idempotency_key(key, reactor_class_name)],
                                    argv: [from_context_id, to_context_id, durability_ttl]) == 1
      end

      private

      def idempotency_key(key, reactor_class_name)
        "reactor:#{reactor_class_name}:idempotency:#{Digest::SHA256.hexdigest(key.to_s)}"
      end
    end
    # rubocop:enable Naming/PredicateMethod
  end
end
