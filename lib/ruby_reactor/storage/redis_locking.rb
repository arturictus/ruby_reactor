# frozen_string_literal: true

module RubyReactor
  module Storage
    module RedisLocking
      # Scripts for Lock Primitives
      LOCK_ACQUIRE_SCRIPT = <<~LUA
        local key = KEYS[1]
        local owner = ARGV[1]
        local ttl = tonumber(ARGV[2])

        if redis.call('exists', key) == 0 then
          redis.call('hset', key, 'owner', owner)
          redis.call('hset', key, 'count', 1)
          redis.call('expire', key, ttl)
          return 1
        elseif redis.call('hget', key, 'owner') == owner then
          redis.call('hincrby', key, 'count', 1)
          redis.call('expire', key, ttl)
          return 1
        else
          return 0
        end
      LUA

      LOCK_RELEASE_SCRIPT = <<~LUA
        local key = KEYS[1]
        local owner = ARGV[1]

        if redis.call('hget', key, 'owner') == owner then
          local new_count = redis.call('hincrby', key, 'count', -1)
          if new_count <= 0 then
            redis.call('del', key)
          end
          return 1
        else
          return 0
        end
      LUA

      # Lock Primitives

      def lock_acquire(key, owner, ttl)
        result = @redis.eval(LOCK_ACQUIRE_SCRIPT, keys: [key], argv: [owner, ttl])
        result == 1
      end

      def lock_release(key, owner)
        result = @redis.eval(LOCK_RELEASE_SCRIPT, keys: [key], argv: [owner])
        result == 1
      end

      # Semaphore Primitives

      def semaphore_init(key, limit)
        # Try to initialize flag
        if @redis.set("#{key}:init", "1", nx: true, ex: 86_400)
          # Push limit tokens
          tokens = Array.new(limit) { "1" }
          @redis.rpush(key, tokens)
          true
        else
          false
        end
      end

      def semaphore_reset(key)
        @redis.del(key)
        @redis.del("#{key}:init")
      end

      def semaphore_acquire(key, timeout: 0)
        # BLPOP returns [key, element] or nil (if timeout)
        # If timeout is 0, we use lpop to make it non-blocking
        result = if timeout.to_f > 0
                   @redis.blpop(key, timeout: timeout)
                 else
                   @redis.lpop(key)
                 end
        !result.nil?
      end

      def semaphore_release(key)
        @redis.rpush(key, "1")
      end

      def semaphore_exists?(key)
        @redis.exists?("#{key}:init")
      end
    end
  end
end
