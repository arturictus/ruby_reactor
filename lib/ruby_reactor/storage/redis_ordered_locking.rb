# frozen_string_literal: true

module RubyReactor
  module Storage
    # Ordered Lock Primitives — used by `with_ordered_lock` to enforce
    # strict transaction ordering via a monotonically increasing nonce
    # assigned at enqueue time. See `RubyReactor::OrderedLock`.
    #
    # Storage layout (hash-tagged so a Redis cluster keeps them on the same
    # shard):
    #   STRING  ordered_lock:{<key>}:next            — last-assigned nonce
    #   STRING  ordered_lock:{<key>}:last_completed  — last-advanced nonce
    #   HASH    ordered_lock:{<key>}:assigned_at     — { nonce => unix_ts }
    #   STRING  ordered_lock:{<key>}:first_failed    — nonce of the FIRST run
    #                                                  whose terminal status
    #                                                  was Failure (strict mode
    #                                                  poison marker; 0 / unset
    #                                                  if no failure yet).
    #   STRING  ordered_lock:{<key>}:epoch            — generation counter,
    #                                                  bumped each time a fresh
    #                                                  batch starts (nonce 1).
    #                                                  Captured at assign and
    #                                                  carried by every gate /
    #                                                  advance call so a stale
    #                                                  straggler from a drained
    #                                                  batch (whose nonce numbers
    #                                                  the next batch reuses)
    #                                                  is fenced out as a no-op.
    #
    # When `last_completed == next`, the next/last_completed/assigned_at/
    # first_failed keys are garbage-collected by the ADVANCE script and the next
    # assign starts at 1 again — a fresh batch always starts un-poisoned. The
    # `epoch` key is deliberately NOT GC'd (only TTL-expires when fully idle) so
    # the generation keeps incrementing across back-to-back batches.
    module RedisOrderedLocking # rubocop:disable Metrics/ModuleLength
      ASSIGN_SCRIPT = <<~LUA
        local next_key  = KEYS[1]
        local last_key  = KEYS[2]
        local at_key    = KEYS[3]
        local epoch_key = KEYS[4]
        local now       = ARGV[1]
        local ttl       = tonumber(ARGV[2])

        local nonce = redis.call('incr', next_key)
        redis.call('expire', next_key, ttl)

        if redis.call('exists', last_key) == 0 then
          redis.call('set', last_key, 0, 'EX', ttl)
        else
          redis.call('expire', last_key, ttl)
        end

        -- nonce == 1 means `next` was absent (first ever, or GC'd after a full
        -- drain), so this is the start of a fresh batch -> bump the generation.
        -- Later nonces in the same batch read the epoch the nonce-1 caller set.
        local epoch
        if nonce == 1 then
          epoch = redis.call('incr', epoch_key)
        else
          epoch = tonumber(redis.call('get', epoch_key) or '1')
        end
        redis.call('expire', epoch_key, ttl)

        redis.call('hset', at_key, nonce, now)
        redis.call('expire', at_key, ttl)
        return {nonce, epoch}
      LUA

      CAN_PROCEED_SCRIPT = <<~LUA
        local next_key  = KEYS[1]
        local last_key  = KEYS[2]
        local at_key    = KEYS[3]
        local fail_key  = KEYS[4]
        local epoch_key = KEYS[5]
        local my        = tonumber(ARGV[1])
        local now       = tonumber(ARGV[2])
        local pp        = tonumber(ARGV[3])
        local my_epoch  = tonumber(ARGV[4] or '0')

        local last = tonumber(redis.call('get', last_key) or '0')
        local first_failed = tonumber(redis.call('get', fail_key) or '0')

        -- Stale-batch fence: a caller carrying an epoch from a drained batch
        -- (whose nonce numbers the current batch reused) must not gate against
        -- or poison-advance this batch. my_epoch == 0 is a legacy/no-epoch
        -- caller (e.g. an in-flight job from before this field existed) — skip.
        local cur_epoch = tonumber(redis.call('get', epoch_key) or '0')
        if my_epoch > 0 and my_epoch ~= cur_epoch then
          return {'stale', 0, last, first_failed}
        end

        -- Drained-batch fence: both counters absent means this caller's batch
        -- fully drained and was GC'd (or wholly TTL-expired) while it slept —
        -- e.g. a poison-passed straggler waking between the drain and the next
        -- batch's first assign (epoch not yet bumped, so the stale fence can't
        -- catch it). It may run late (poison semantics) but must NOT enter the
        -- poison loop below: SET on the missing last_key would resurrect the
        -- cursor with no TTL and let every nonce of the NEXT batch gate
        -- straight through. Only both-absent is conclusive — a mid-batch
        -- next_key TTL hiccup leaves last_key in place and proceeds normally.
        if redis.call('exists', next_key) == 0 and redis.call('exists', last_key) == 0 then
          return {'go', 0, last, first_failed}
        end

        -- Liveness heartbeat: a gate check proves this caller is alive (about
        -- to run, or snoozing on lock/rate contention and re-checking), so
        -- restamp its own assigned_at. assigned_at is otherwise set once at
        -- ENQUEUE, meaning a job that merely sat in a deep queue longer than
        -- poison_pill_timeout would be poison-passed the moment a successor
        -- gates — this restamp gives it a full pp window from the time it
        -- actually starts. hexists guard: never resurrect an entry that an
        -- out-of-order terminal advance already deleted.
        if my > last and redis.call('hexists', at_key, my) == 1 then
          redis.call('hset', at_key, my, now)
        end

        if my <= last then
          return {'go', 0, last, first_failed}
        end

        if my == last + 1 then
          return {'go', 0, last, first_failed}
        end

        -- Drain consecutive poisoned blockers in one shot. Without this loop a
        -- cluster of N dead blockers takes N snooze rounds to clear (one round
        -- per blocker); with it, a single can_proceed call sweeps them all.
        -- Bounded by `my` so the loop runs at most O(stream length) per call.
        local advanced_via_poison = false
        while last + 1 < my do
          local blocker = last + 1
          local at = tonumber(redis.call('hget', at_key, blocker) or '0')
          -- Only a blocker with a recent assigned_at timestamp is genuinely in
          -- flight; stop draining there. `at == 0` means the timer is gone (an
          -- out-of-order advance deleted it, or the assigned_at hash expired),
          -- so the blocker can never make progress on its own — advance past it
          -- rather than stalling forever (the original `break` here was a
          -- permanent head-of-line hang, the exact thing poison-pill prevents).
          if at > 0 and (now - at) <= pp then
            break
          end
          redis.call('set', last_key, blocker, 'KEEPTTL')
          redis.call('hdel', at_key, blocker)
          last = blocker
          advanced_via_poison = true
        end

        if my <= last then
          return {advanced_via_poison and 'poison_advance' or 'go', 0, last, first_failed}
        end

        if my == last + 1 then
          return {advanced_via_poison and 'poison_advance' or 'go', 0, last, first_failed}
        end

        local blocker = last + 1
        local blocker_assigned = tonumber(redis.call('hget', at_key, blocker) or '0')
        local hint
        if blocker_assigned > 0 then
          hint = pp - (now - blocker_assigned)
        else
          hint = pp
        end
        if hint < 1 then hint = 1 end
        return {'wait', hint, last, first_failed}
      LUA

      ADVANCE_SCRIPT = <<~LUA
        local next_key  = KEYS[1]
        local last_key  = KEYS[2]
        local at_key    = KEYS[3]
        local fail_key  = KEYS[4]
        local epoch_key = KEYS[5]
        local my        = tonumber(ARGV[1])
        local failed    = tonumber(ARGV[2]) == 1
        local ttl       = tonumber(ARGV[3])
        local my_epoch  = tonumber(ARGV[4] or '0')

        -- Stale-batch fence: an advance carrying an epoch from a drained batch
        -- whose nonce numbers were reused must not mutate the current batch's
        -- counters. This is the core protection against a slow straggler from a
        -- prior batch corrupting a later one. my_epoch == 0 = legacy caller.
        local cur_epoch = tonumber(redis.call('get', epoch_key) or '0')
        if my_epoch > 0 and my_epoch ~= cur_epoch then
          return tonumber(redis.call('get', last_key) or '0')
        end

        -- Drained-batch fence (mirrors CAN_PROCEED): a late terminal from a
        -- batch that already drained and GC'd must be a complete no-op. Without
        -- it, an in-order straggler advance (my == 0 + 1) would SET last_key
        -- with KEEPTTL on a missing key — resurrecting a TTL-less cursor that
        -- un-gates every nonce of the next batch — and a failed straggler
        -- would write fail_key, strict-poisoning a batch that hasn't started.
        if redis.call('exists', next_key) == 0 and redis.call('exists', last_key) == 0 then
          return 0
        end

        local last = tonumber(redis.call('get', last_key) or '0')

        -- Record the chain poison marker for ANY terminal failure ahead of the
        -- cursor (my > last), not just the in-order successor; strict-mode
        -- chain-skip relies on the SMALLEST failed nonce being recorded. A
        -- failure at or behind the cursor (my <= last) is deliberately NOT
        -- recorded: that guard is what keeps a Sidekiq duplicate redelivery of
        -- an already-terminated failure from re-poisoning a chain that moved
        -- on. Cost of the trade-off: a run the poison-advance already passed
        -- (cursor moved beyond it) that later fails does NOT poison the chain
        -- — by then ordering was already ceded for that nonce and successors
        -- may have run.
        if failed and my > last then
          local existing = tonumber(redis.call('get', fail_key) or '0')
          if existing == 0 or my < existing then
            redis.call('set', fail_key, my, 'EX', ttl)
          end
        end

        if my == last + 1 then
          redis.call('set', last_key, my, 'KEEPTTL')
          redis.call('hdel', at_key, my)
          last = my

          local nxt = tonumber(redis.call('get', next_key) or '0')
          -- Guard with `nxt > 0` (mirroring SKIP_SCRIPT): a missing/expired
          -- next_key reads as 0 and `last >= 0` would otherwise GC live
          -- counters mid-sequence, resetting numbering and dropping the marker.
          if last >= nxt and nxt > 0 then
            redis.call('del', next_key)
            redis.call('del', last_key)
            redis.call('del', at_key)
            redis.call('del', fail_key)
          end
          return last
        end

        redis.call('hdel', at_key, my)
        return last
      LUA

      SKIP_SCRIPT = <<~LUA
        local next_key = KEYS[1]
        local last_key = KEYS[2]
        local at_key   = KEYS[3]
        local fail_key = KEYS[4]
        local my       = tonumber(ARGV[1])

        -- Drained-batch fence (mirrors CAN_PROCEED/ADVANCE): an ops `skip!` of a
        -- nonce whose batch already drained must not SET last_key on a missing
        -- key — KEEPTTL on an absent key would create a TTL-less cursor and
        -- un-gate the next batch. Nothing to skip in a drained batch anyway.
        if redis.call('exists', next_key) == 0 and redis.call('exists', last_key) == 0 then
          return 0
        end

        local last = tonumber(redis.call('get', last_key) or '0')

        if my > last then
          -- KEEPTTL: forcing the cursor forward must not strip the sequence TTL
          -- and leave a persistent key behind for a sequence that never drains.
          redis.call('set', last_key, my, 'KEEPTTL')
        end
        redis.call('hdel', at_key, my)

        last = tonumber(redis.call('get', last_key) or '0')
        local nxt = tonumber(redis.call('get', next_key) or '0')
        if last >= nxt and nxt > 0 then
          redis.call('del', next_key)
          redis.call('del', last_key)
          redis.call('del', at_key)
          redis.call('del', fail_key)
        end
        return last
      LUA

      # Returns `[nonce, epoch]`: the assigned nonce plus the generation it
      # belongs to. The caller stashes both so later gate/advance calls can be
      # fenced if the batch drains and its numbers get reused.
      def ordered_lock_assign(key, ttl: 86_400, now: Time.now.to_i)
        next_k, last_k, at_k, _fail_k, epoch_k = ordered_lock_keys(key)
        nonce, epoch = @redis.eval(
          ASSIGN_SCRIPT, keys: [next_k, last_k, at_k, epoch_k], argv: [now.to_s, ttl]
        )
        [nonce.to_i, epoch.to_i]
      end

      def ordered_lock_can_proceed(key, nonce:, poison_pill_timeout:, epoch: 0, now: Time.now.to_i)
        state, retry_after, last_completed, first_failed = @redis.eval(
          CAN_PROCEED_SCRIPT,
          keys: ordered_lock_keys(key),
          argv: [nonce.to_i, now.to_i, poison_pill_timeout.to_i, epoch.to_i]
        )
        [state.to_s, retry_after.to_i, last_completed.to_i, first_failed.to_i]
      end

      def ordered_lock_advance(key, nonce:, failed: false, epoch: 0, ttl: 86_400)
        @redis.eval(
          ADVANCE_SCRIPT,
          keys: ordered_lock_keys(key),
          argv: [nonce.to_i, failed ? 1 : 0, ttl.to_i, epoch.to_i]
        ).to_i
      end

      def ordered_lock_skip(key, nonce:)
        @redis.eval(SKIP_SCRIPT, keys: ordered_lock_keys(key), argv: [nonce.to_i]).to_i
      end

      def ordered_lock_reset(key)
        @redis.del(*ordered_lock_keys(key))
      end

      def ordered_lock_peek(key)
        next_k, last_k, at_k, fail_k = ordered_lock_keys(key)
        next_v = @redis.get(next_k)
        last_v = @redis.get(last_k)
        fail_v = @redis.get(fail_k)
        in_flight = @redis.hkeys(at_k).map(&:to_i).sort
        {
          next: next_v ? next_v.to_i : 0,
          last_completed: last_v ? last_v.to_i : 0,
          in_flight: in_flight,
          first_failed: fail_v ? fail_v.to_i : 0
        }
      end

      # Order matters: callers destructure positionally and some scripts take a
      # subset. `epoch` is appended last so existing 4-key destructures keep
      # working unchanged.
      def ordered_lock_keys(key)
        tag = "{#{key}}"
        [
          "ordered_lock:#{tag}:next",
          "ordered_lock:#{tag}:last_completed",
          "ordered_lock:#{tag}:assigned_at",
          "ordered_lock:#{tag}:first_failed",
          "ordered_lock:#{tag}:epoch"
        ]
      end
    end
  end
end
