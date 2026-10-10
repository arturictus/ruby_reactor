# frozen_string_literal: true

require "digest"

module RubyReactor
  module Storage
    # Run-level idempotency keys (011 R-15): the first caller claims `key` for
    # its run; later callers get that run's id back. Kept for `context_ttl`,
    # the same horizon as the run it points at.
    module RedisIdempotency
      def claim_idempotency_key(key, context_id, reactor_class_name)
        redis_key = "reactor:#{reactor_class_name}:idempotency:#{Digest::SHA256.hexdigest(key.to_s)}"
        @redis.set(redis_key, context_id, nx: true, ex: durability_ttl) ? nil : @redis.get(redis_key)
      end
    end
  end
end
