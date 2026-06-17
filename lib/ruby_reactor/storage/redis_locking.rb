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

      # Period Primitives — used by `with_period` to dedup bucketed runs.

      def period_seen?(key)
        @redis.exists?(key)
      end

      def period_mark(key, ttl)
        @redis.set(key, "1", ex: ttl)
      end

      # Rate Limit Primitives — fixed-window counter, supports multiple
      # windows in one atomic call. Two-pass inside Lua so a miss on the Nth
      # window does not leave the previous N-1 incremented.
      #
      # ARGV layout: [now, period_1, limit_1, ttl_1, period_2, limit_2, ttl_2, ...]
      # KEYS:        [bucket_key_1, bucket_key_2, ...]
      # Returns:     [allowed (1|0), retry_after_seconds, failed_index]

      RATE_LIMIT_SCRIPT = <<~LUA
        local now = tonumber(ARGV[1])
        local n = #KEYS

        for i = 1, n do
          local base = 2 + (i - 1) * 3
          local period = tonumber(ARGV[base])
          local lim = tonumber(ARGV[base + 1])
          local count = tonumber(redis.call('get', KEYS[i]) or '0')
          if count >= lim then
            local retry_after = period - (now % period)
            if retry_after <= 0 then retry_after = 1 end
            return {0, retry_after, i}
          end
        end

        for i = 1, n do
          local base = 2 + (i - 1) * 3
          local ttl = tonumber(ARGV[base + 2])
          local count = redis.call('incr', KEYS[i])
          if count == 1 then
            redis.call('expire', KEYS[i], ttl)
          end
        end

        return {1, 0, 0}
      LUA

      def rate_limit_check_and_increment(keys, argv)
        @redis.eval(RATE_LIMIT_SCRIPT, keys: keys, argv: argv)
      end

      # Inspectors — used by RSpec matchers to assert on lock/semaphore/
      # rate-limit/period state without leaking Redis-specific calls into
      # test code.

      # Liveness check for a logical lock by its BARE key (e.g. "async:<id>").
      # Prepends the "lock:" prefix that Lock applies. True while a worker holds
      # (and auto-extends) the lock; false once it expires — the sweeper's
      # "worker died" signal.
      def lock_held?(key)
        @redis.exists?("lock:#{key}")
      end

      # Returns { owner:, count: } for a held lock, or nil if free.
      # `prefixed_key` is the full key (e.g. "lock:order:42").
      def lock_info(prefixed_key)
        return nil unless @redis.exists?(prefixed_key)

        data = @redis.hgetall(prefixed_key)
        return nil if data.empty?

        { owner: data["owner"], count: data["count"].to_i }
      end

      # Returns { available:, held:, limit: } for a semaphore. `name` is the
      # user-provided semaphore key (without the "semaphore:" prefix).
      def semaphore_state(name)
        prefix = "semaphore:#{name}"
        {
          available: @redis.llen(prefix),
          held: @redis.scard("#{prefix}:held"),
          limit: @redis.get("#{prefix}:init").to_i
        }
      end

      # Current count for a rate-limit bucket. `key_base` is the user's
      # `with_rate_limit` key, `every` is the period (symbol or seconds).
      def rate_limit_count(key_base, every, now: Time.now.to_i)
        period_seconds = RubyReactor::Period.period_seconds(every)
        bucket = now / period_seconds
        @redis.get("rate:#{key_base}:#{every}:#{bucket}").to_i
      end

      # Has a period bucket been marked? `key_base` is the user's
      # `with_period` key, `every` is the period.
      def period_marker?(key_base, every, now: Time.now.utc)
        @redis.exists?(RubyReactor::Period.key(key_base, every, now: now))
      end

      # TTL in seconds for a held lock (-2 if key does not exist).
      def lock_ttl(prefixed_key)
        @redis.ttl(prefixed_key)
      end

      # TTL in seconds for the current rate-limit bucket (-2 if unset).
      def rate_limit_ttl(key_base, every, now: Time.now.to_i)
        period_seconds = RubyReactor::Period.period_seconds(every)
        bucket = now / period_seconds
        @redis.ttl("rate:#{key_base}:#{every}:#{bucket}")
      end

      # TTL in seconds for a period marker (-2 if unset).
      def period_ttl(key_base, every, now: Time.now.utc)
        @redis.ttl(RubyReactor::Period.key(key_base, every, now: now))
      end
    end
    # rubocop:enable Naming/PredicateMethod
  end
end
