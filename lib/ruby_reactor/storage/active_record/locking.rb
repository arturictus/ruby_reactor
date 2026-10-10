# frozen_string_literal: true

module RubyReactor
  module Storage
    class ActiveRecordAdapter
      # Locks, semaphores, rate limits and periods. Each `*_SCRIPT` twin below
      # keeps the control flow of its Lua original in RedisLocking line for
      # line, so a reviewer can diff the two; `Coordination.atomically` gives it
      # the Lua script's atomicity over its KEYS (011 R-04).
      module Locking
        # -- twin of RedisLocking::LOCK_ACQUIRE_SCRIPT
        def lock_acquire(key, owner, ttl)
          owner = owner.to_s
          Coordination.atomically([key], op: "lock_acquire") do |kv|
            if !kv.exists(key)
              kv.hset(key, "owner", owner)
              kv.hset(key, "count", 1)
              kv.expire(key, ttl)
              true
            elsif kv.hget(key, "owner") == owner
              kv.hincrby(key, "count", 1)
              kv.expire(key, ttl)
              true
            else
              false
            end
          end
        end

        # -- twin of RedisLocking::LOCK_RELEASE_SCRIPT
        def lock_release(key, owner)
          Coordination.atomically([key], op: "lock_release") do |kv|
            if kv.hget(key, "owner") == owner.to_s
              new_count = kv.hincrby(key, "count", -1)
              kv.del(key) if new_count <= 0
              true
            else
              false
            end
          end
        end

        # -- twin of RedisLocking::LOCK_EXTEND_SCRIPT
        def lock_extend(key, owner, ttl)
          Coordination.atomically([key], op: "lock_extend") do |kv|
            if kv.hget(key, "owner") == owner.to_s
              kv.expire(key, ttl)
              true
            else
              false
            end
          end
        end

        # Semaphores: LIST <key> of available tokens, SET <key>:held, STRING
        # <key>:init — the RedisLocking layout.
        def semaphore_init(key, limit)
          init = "#{key}:init"
          Coordination.atomically([key, init], op: "semaphore_init") do |kv|
            next false unless kv.set(init, limit, nx: true, ex: RedisLocking::SEMAPHORE_TTL)

            kv.rpush(key, *Array.new(limit) { SecureRandom.uuid })
            kv.expire(key, RedisLocking::SEMAPHORE_TTL)
            true
          end
        end

        def semaphore_reset(key)
          keys = [key, "#{key}:held", "#{key}:init"]
          Coordination.atomically(keys, op: "semaphore_reset") { |kv| keys.sum { |k| kv.del(k) } }
        end

        def semaphore_held(key, token)
          Coordination.peek(["#{key}:held"]) { |kv| kv.sismember("#{key}:held", token) }
        end
        alias semaphore_held? semaphore_held

        # `timeout > 0` polls instead of BLPOP: a blocking wait would hold a
        # pooled connection (and its row locks) for the whole timeout.
        def semaphore_acquire(key, timeout: 0)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout.to_f
          loop do
            token = semaphore_acquire_once(key)
            return token if token || timeout.to_f <= 0
            return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

            sleep 0.05
          end
        end

        # -- twin of RedisLocking::SEM_RELEASE_SCRIPT
        def semaphore_release(key, token, limit)
          return false unless token

          held_key = "#{key}:held"
          Coordination.atomically([key, held_key], op: "semaphore_release") do |kv|
            if kv.srem(held_key, token).zero? || kv.llen(key) >= limit.to_i
              false
            else
              kv.rpush(key, token)
              true
            end
          end
        end

        def semaphore_exists?(key)
          Coordination.peek(["#{key}:init"]) { |kv| kv.exists("#{key}:init") }
        end

        # -- twin of RedisLocking::RATE_LIMIT_SCRIPT
        # ARGV: [now, period_1, limit_1, ttl_1, period_2, limit_2, ttl_2, ...]
        # Returns [allowed (1|0), retry_after_seconds, failed_index].
        def rate_limit_check_and_increment(keys, argv)
          now = argv[0].to_i
          Coordination.atomically(keys, op: "rate_limit") do |kv|
            denied = keys.each_with_index.lazy.filter_map do |bucket, i|
              base = 1 + (i * 3)
              period = argv[base].to_i
              next unless kv.get(bucket).to_i >= argv[base + 1].to_i

              retry_after = period - (now % period)
              [0, retry_after <= 0 ? 1 : retry_after, i + 1]
            end.first
            next denied if denied

            keys.each_with_index do |bucket, i|
              kv.expire(bucket, argv[1 + (i * 3) + 2].to_i) if kv.incr(bucket) == 1
            end
            [1, 0, 0]
          end
        end

        # Periods: a permanent row per claimed bucket (R-15); `ttl` is the Redis
        # adapter's horizon and ignored here.
        def period_seen?(key)
          with_db { PeriodMarker.exists?(key_digest: Coordination.digest(key)) }
        end

        def period_mark(key, _ttl, context_id: nil)
          with_db do
            PeriodMarker.insert_all([{ key_digest: Coordination.digest(key), key: key.to_s, context_id: context_id,
                                       claimed_at: Time.current }])
          end
        end

        def period_marker?(key_base, every, now: Time.now.utc)
          period_seen?(RubyReactor::Period.key(key_base, every, now: now))
        end

        # `{ context_id:, claimed_at: }` for a marked period bucket, or nil.
        def period_marker_info(key_base, every, now: Time.now.utc)
          digest = Coordination.digest(RubyReactor::Period.key(key_base, every, now: now))
          context_id, claimed_at = with_db { PeriodMarker.where(key_digest: digest).pick(:context_id, :claimed_at) }
          claimed_at && { context_id: context_id, claimed_at: claimed_at }
        end

        # -1 (persistent) while the marker exists, -2 otherwise — Redis TTL codes.
        def period_ttl(key_base, every, now: Time.now.utc)
          period_marker?(key_base, every, now: now) ? -1 : -2
        end

        # Inspectors (read-only, lock-free: R-04).

        def lock_held?(key)
          Coordination.peek(["lock:#{key}"]) { |kv| kv.exists("lock:#{key}") }
        end

        def lock_info(prefixed_key)
          Coordination.peek([prefixed_key]) do |kv|
            data = kv.hgetall(prefixed_key)
            data.empty? ? nil : { owner: data["owner"], count: data["count"].to_i }
          end
        end

        def lock_ttl(prefixed_key)
          Coordination.peek([prefixed_key]) { |kv| kv.ttl(prefixed_key) }
        end

        def semaphore_state(name)
          prefix = "semaphore:#{name}"
          Coordination.peek([prefix, "#{prefix}:held", "#{prefix}:init"]) do |kv|
            { available: kv.llen(prefix), held: kv.scard("#{prefix}:held"), limit: kv.get("#{prefix}:init").to_i }
          end
        end

        def rate_limit_count(key_base, every, now: Time.now.to_i)
          key = rate_limit_key(key_base, every, now)
          Coordination.peek([key]) { |kv| kv.get(key).to_i }
        end

        def rate_limit_ttl(key_base, every, now: Time.now.to_i)
          key = rate_limit_key(key_base, every, now)
          Coordination.peek([key]) { |kv| kv.ttl(key) }
        end

        private

        # -- twin of RedisLocking::SEM_ACQUIRE_SCRIPT, plus the held-set expiry
        # RedisLocking#semaphore_acquire applies after it.
        def semaphore_acquire_once(key)
          held_key = "#{key}:held"
          Coordination.atomically([key, held_key], op: "semaphore_acquire") do |kv|
            token = kv.lpop(key)
            next nil unless token

            kv.sadd(held_key, token)
            kv.expire(held_key, RedisLocking::SEMAPHORE_TTL)
            token
          end
        end

        def rate_limit_key(key_base, every, now)
          "rate:#{key_base}:#{every}:#{now / RubyReactor::Period.period_seconds(every)}"
        end
      end
    end
  end
end
