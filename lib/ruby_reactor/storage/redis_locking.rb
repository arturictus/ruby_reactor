# frozen_string_literal: true

module RubyReactor
  module Storage
    # Adapter contract uses non-`?` names for methods that return booleans
    # (`lock_acquire`, `semaphore_release`, etc). Renaming would break the
    # public storage adapter API, so silence the predicate-name cop here.
    # rubocop:disable Naming/PredicateMethod
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

      LOCK_EXTEND_SCRIPT = <<~LUA
        local key = KEYS[1]
        local owner = ARGV[1]
        local ttl = tonumber(ARGV[2])

        if redis.call('hget', key, 'owner') == owner then
          redis.call('expire', key, ttl)
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

      def lock_extend(key, owner, ttl)
        result = @redis.eval(LOCK_EXTEND_SCRIPT, keys: [key], argv: [owner, ttl])
        result == 1
      end

      # Semaphore Primitives
      #
      # Storage layout:
      #   LIST   <key>       — available token UUIDs
      #   SET    <key>:held  — tokens currently checked out
      #   STRING <key>:init  — sentinel marking that init has run; value = limit
      #
      # Tokens are unique UUIDs so release can verify the caller actually holds
      # one before pushing it back, blocking double-release and over-cap RPUSH.

      SEM_ACQUIRE_SCRIPT = <<~LUA
        local list_key = KEYS[1]
        local held_key = KEYS[2]
        local token = redis.call('lpop', list_key)
        if not token then return false end
        redis.call('sadd', held_key, token)
        return token
      LUA

      SEM_RELEASE_SCRIPT = <<~LUA
        local list_key = KEYS[1]
        local held_key = KEYS[2]
        local limit = tonumber(ARGV[1])
        local token = ARGV[2]
        if redis.call('srem', held_key, token) == 0 then
          return 0
        end
        if redis.call('llen', list_key) >= limit then
          return 0
        end
        redis.call('rpush', list_key, token)
        return 1
      LUA

      SEMAPHORE_TTL = 86_400

      def semaphore_init(key, limit)
        return false unless @redis.set("#{key}:init", limit, nx: true, ex: SEMAPHORE_TTL)

        tokens = Array.new(limit) { SecureRandom.uuid }
        @redis.rpush(key, tokens)
        @redis.expire(key, SEMAPHORE_TTL)
        true
      end

      def semaphore_reset(key)
        @redis.del(key)
        @redis.del("#{key}:held")
        @redis.del("#{key}:init")
      end

      def semaphore_acquire(key, timeout: 0)
        held_key = "#{key}:held"

        token = if timeout.to_f.positive?
                  result = @redis.blpop(key, timeout: timeout)
                  next_token = result&.last
                  @redis.sadd(held_key, next_token) if next_token
                  next_token
                else
                  @redis.eval(SEM_ACQUIRE_SCRIPT, keys: [key, held_key], argv: [])
                end

        return nil unless token

        @redis.expire(held_key, SEMAPHORE_TTL)
        token
      end

      def semaphore_release(key, token, limit)
        return false unless token

        result = @redis.eval(
          SEM_RELEASE_SCRIPT,
          keys: [key, "#{key}:held"],
          argv: [limit, token]
        )
        result == 1
      end

      def semaphore_exists?(key)
        @redis.exists?("#{key}:init")
      end
    end
    # rubocop:enable Naming/PredicateMethod
  end
end
