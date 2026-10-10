# frozen_string_literal: true

module RubyReactor
  module Storage
    class ActiveRecordAdapter
      # `with_ordered_lock` primitives. Each method is a twin of the Lua script
      # of the same name in RedisOrderedLocking — same keys, same per-key TTLs,
      # same fences, same return tuples — kept statement for statement so the
      # two can be diffed. The rationale for every branch lives in the Lua
      # comments; they are not repeated here.
      module OrderedLocking
        # -- twin of RedisOrderedLocking::ASSIGN_SCRIPT
        def ordered_lock_assign(key, ttl: 86_400, now: Time.now.to_i)
          next_k, last_k, at_k, _fail_k, epoch_k = ordered_lock_keys(key)
          Coordination.atomically([next_k, last_k, at_k, epoch_k], op: "ordered_lock_assign") do |kv|
            nonce = kv.incr(next_k)
            kv.expire(next_k, ttl)

            if kv.exists(last_k)
              kv.expire(last_k, ttl)
            else
              kv.set(last_k, 0, ex: ttl)
            end

            epoch = nonce == 1 ? kv.incr(epoch_k) : (kv.get(epoch_k) || "1").to_i
            kv.expire(epoch_k, ttl)

            kv.hset(at_k, nonce, now)
            kv.expire(at_k, ttl)
            [nonce, epoch]
          end
        end

        # -- twin of RedisOrderedLocking::CAN_PROCEED_SCRIPT
        def ordered_lock_can_proceed(key, nonce:, poison_pill_timeout:, epoch: 0, now: Time.now.to_i) # rubocop:disable Metrics/MethodLength
          keys = ordered_lock_keys(key)
          next_k, last_k, at_k, fail_k, epoch_k = keys
          my = nonce.to_i
          now = now.to_i
          pp = poison_pill_timeout.to_i
          my_epoch = epoch.to_i

          Coordination.atomically(keys, op: "ordered_lock_can_proceed") do |kv|
            last = kv.get(last_k).to_i
            first_failed = kv.get(fail_k).to_i

            cur_epoch = kv.get(epoch_k).to_i
            next ["stale", 0, last, first_failed] if my_epoch.positive? && my_epoch != cur_epoch

            next ["drained_go", 0, last, first_failed] if !kv.exists(next_k) && !kv.exists(last_k)

            kv.hset(at_k, my, now) if my > last && kv.hexists(at_k, my)

            next ["go", 0, last, first_failed] if my <= last || my == last + 1

            advanced_via_poison = false
            while last + 1 < my
              blocker = last + 1
              at = kv.hget(at_k, blocker).to_i
              break if at.positive? && (now - at) <= pp

              kv.set(last_k, blocker, keepttl: true)
              kv.hdel(at_k, blocker)
              last = blocker
              advanced_via_poison = true
            end

            state = advanced_via_poison ? "poison_advance" : "go"
            next [state, 0, last, first_failed] if my <= last || my == last + 1

            blocker_assigned = kv.hget(at_k, last + 1).to_i
            hint = blocker_assigned.positive? ? pp - (now - blocker_assigned) : pp
            ["wait", [hint, 1].max, last, first_failed]
          end
        end

        # -- twin of RedisOrderedLocking::ADVANCE_SCRIPT
        def ordered_lock_advance(key, nonce:, failed: false, epoch: 0, ttl: 86_400)
          keys = ordered_lock_keys(key)
          next_k, last_k, at_k, fail_k, epoch_k = keys
          my = nonce.to_i
          my_epoch = epoch.to_i

          Coordination.atomically(keys, op: "ordered_lock_advance") do |kv|
            cur_epoch = kv.get(epoch_k).to_i
            next kv.get(last_k).to_i if my_epoch.positive? && my_epoch != cur_epoch

            next 0 if !kv.exists(next_k) && !kv.exists(last_k)

            last = kv.get(last_k).to_i

            if failed && my > last
              existing = kv.get(fail_k).to_i
              kv.set(fail_k, my, ex: ttl) if existing.zero? || my < existing
            end

            if my == last + 1
              kv.set(last_k, my, keepttl: true)
              kv.hdel(at_k, my)
              last = my

              nxt = kv.get(next_k).to_i
              [next_k, last_k, at_k, fail_k].each { |k| kv.del(k) } if last >= nxt && nxt.positive?
              next last
            end

            kv.hdel(at_k, my)
            last
          end
        end

        # -- twin of RedisOrderedLocking::HEARTBEAT_SCRIPT
        def ordered_lock_heartbeat(key, nonce:, epoch: 0, now: Time.now.to_i)
          _next_k, _last_k, at_k, _fail_k, epoch_k = ordered_lock_keys(key)
          my_epoch = epoch.to_i

          Coordination.atomically([at_k, epoch_k], op: "ordered_lock_heartbeat") do |kv|
            cur_epoch = kv.get(epoch_k).to_i
            next 0 if my_epoch.positive? && my_epoch != cur_epoch

            if kv.hexists(at_k, nonce.to_i)
              kv.hset(at_k, nonce.to_i, now.to_i)
              1
            else
              0
            end
          end
        end

        # -- twin of RedisOrderedLocking::SKIP_SCRIPT
        def ordered_lock_skip(key, nonce:)
          next_k, last_k, at_k, fail_k, = ordered_lock_keys(key)
          my = nonce.to_i

          Coordination.atomically([next_k, last_k, at_k, fail_k], op: "ordered_lock_skip") do |kv|
            next 0 if !kv.exists(next_k) && !kv.exists(last_k)

            kv.set(last_k, my, keepttl: true) if my > kv.get(last_k).to_i
            kv.hdel(at_k, my)

            last = kv.get(last_k).to_i
            nxt = kv.get(next_k).to_i
            [next_k, last_k, at_k, fail_k].each { |k| kv.del(k) } if last >= nxt && nxt.positive?
            last
          end
        end

        def ordered_lock_reset(key)
          keys = ordered_lock_keys(key)
          Coordination.atomically(keys, op: "ordered_lock_reset") { |kv| keys.sum { |k| kv.del(k) } }
        end

        def ordered_lock_peek(key)
          next_k, last_k, at_k, fail_k = ordered_lock_keys(key)
          Coordination.peek([next_k, last_k, at_k, fail_k]) do |kv|
            {
              next: kv.get(next_k).to_i,
              last_completed: kv.get(last_k).to_i,
              in_flight: kv.hkeys(at_k).map(&:to_i).sort,
              first_failed: kv.get(fail_k).to_i
            }
          end
        end

        # The same five key names as Redis — pure, no database access.
        def ordered_lock_keys(key)
          RedisOrderedLocking.instance_method(:ordered_lock_keys).bind_call(self, key)
        end
      end
    end
  end
end
