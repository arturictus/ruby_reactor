# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyReactor::Storage::RedisOrderedLocking do
  let(:adapter) { RubyReactor.configuration.storage_adapter }
  let(:key) { "test_key" }

  describe "#ordered_lock_assign" do
    it "returns monotonically increasing nonces" do
      n1, = adapter.ordered_lock_assign(key)
      n2, = adapter.ordered_lock_assign(key)
      n3, = adapter.ordered_lock_assign(key)
      expect([n1, n2, n3]).to eq([1, 2, 3])
    end

    it "returns the generation epoch alongside the nonce" do
      _n1, e1 = adapter.ordered_lock_assign(key) # first batch -> epoch 1
      _n2, e2 = adapter.ordered_lock_assign(key) # same batch -> same epoch
      expect([e1, e2]).to eq([1, 1])
    end

    it "initialises last_completed to 0" do
      adapter.ordered_lock_assign(key)
      expect(adapter.ordered_lock_peek(key)[:last_completed]).to eq(0)
    end

    it "tracks assigned_at per nonce" do
      adapter.ordered_lock_assign(key, now: 1000)
      adapter.ordered_lock_assign(key, now: 1001)
      expect(adapter.ordered_lock_peek(key)[:in_flight]).to eq([1, 2])
    end

    it "scopes counters per key" do
      adapter.ordered_lock_assign("a")
      adapter.ordered_lock_assign("a")
      n_b, = adapter.ordered_lock_assign("b")
      expect(n_b).to eq(1)
    end
  end

  describe "#ordered_lock_can_proceed" do
    before { 3.times { adapter.ordered_lock_assign(key, now: 1000) } }

    it "returns go when nonce == last_completed + 1" do
      state, _retry_after, last = adapter.ordered_lock_can_proceed(key, nonce: 1, poison_pill_timeout: 60)
      expect(state).to eq("go")
      expect(last).to eq(0)
    end

    it "returns wait when nonce > last_completed + 1" do
      state, retry_after, last = adapter.ordered_lock_can_proceed(
        key, nonce: 2, poison_pill_timeout: 60, now: 1010
      )
      expect(state).to eq("wait")
      expect(last).to eq(0)
      expect(retry_after).to be_between(1, 60).inclusive
    end

    it "returns go when stale (nonce <= last_completed) — idempotent for retries" do
      adapter.ordered_lock_advance(key, nonce: 1)
      state, = adapter.ordered_lock_can_proceed(key, nonce: 1, poison_pill_timeout: 60)
      expect(state).to eq("go")
    end

    it "auto-advances past a poisoned blocker after poison_pill_timeout" do
      # blocker = nonce 1, assigned at 1000. now=1100, pp=60 → blocker expired.
      state, _retry, last = adapter.ordered_lock_can_proceed(
        key, nonce: 2, poison_pill_timeout: 60, now: 1100
      )
      expect(state).to eq("poison_advance")
      expect(last).to eq(1)
    end

    it "drains a chain of stale blockers in a single call" do
      # 3 nonces assigned at 1000. Caller has nonce 3, now=1100, pp=60.
      # Nonces 1 AND 2 are stale → cursor should jump to 2 and gate go.
      state, _retry, last = adapter.ordered_lock_can_proceed(
        key, nonce: 3, poison_pill_timeout: 60, now: 1100
      )
      expect(state).to eq("poison_advance")
      expect(last).to eq(2)
    end

    it "stops draining at the first non-stale blocker" do
      # Add a fresh nonce 4 at 1050. now=1100, pp=60.
      # Stale: 1, 2, 3 (all at 1000). Fresh: 4. My = 5 → drain to 3, then wait on 4.
      adapter.ordered_lock_assign(key, now: 1050) # nonce 4
      adapter.ordered_lock_assign(key, now: 1050) # nonce 5
      state, _retry, last = adapter.ordered_lock_can_proceed(
        key, nonce: 5, poison_pill_timeout: 60, now: 1100
      )
      expect(state).to eq("wait")
      expect(last).to eq(3)
    end
  end

  describe "assigned_at liveness heartbeat on gate check" do
    before { 2.times { adapter.ordered_lock_assign(key, now: 1000) } } # nonces 1, 2

    it "restamps the caller's own assigned_at so a long-queued live job is not poison-passed" do
      # Nonce 1 checks in at 1090 — alive, about to run — restamping its timer.
      adapter.ordered_lock_can_proceed(key, nonce: 1, poison_pill_timeout: 60, now: 1090)

      # At 1100, pre-heartbeat nonce 1 (stamped 1000) was 100s old > pp 60 and
      # nonce 2 would poison-pass it. Post-heartbeat it's only 10s old -> live.
      state, _retry, last = adapter.ordered_lock_can_proceed(
        key, nonce: 2, poison_pill_timeout: 60, now: 1100
      )
      expect(state).to eq("wait")
      expect(last).to eq(0)
    end

    it "does not resurrect an assigned_at entry a terminal advance already deleted" do
      # Out-of-order terminal advance of nonce 2 deletes its assigned_at entry.
      adapter.ordered_lock_advance(key, nonce: 2)
      _next_k, _last_k, at_k = adapter.ordered_lock_keys(key)
      expect(redis.hexists(at_k, "2")).to be(false)

      # A late gate check for nonce 2 must NOT recreate the entry (hexists guard).
      adapter.ordered_lock_can_proceed(key, nonce: 2, poison_pill_timeout: 60, now: 1100)
      expect(redis.hexists(at_k, "2")).to be(false)
    end
  end

  describe "#ordered_lock_heartbeat (running-blocker liveness)" do
    before { 2.times { adapter.ordered_lock_assign(key, now: 1000) } } # nonces 1, 2

    it "restamps a running blocker so a successor does not poison-pass it" do
      # Nonce 1 passed its gate at 1000 and is running long steps. Without a
      # heartbeat, at 1100 its timer (1000) is 100s old > pp 60 and nonce 2
      # poison-passes it. A heartbeat at 1090 keeps it alive.
      restamped = adapter.ordered_lock_heartbeat(key, nonce: 1, now: 1090)
      expect(restamped).to eq(1)

      state, _retry, last = adapter.ordered_lock_can_proceed(
        key, nonce: 2, poison_pill_timeout: 60, now: 1100
      )
      expect(state).to eq("wait")
      expect(last).to eq(0)
    end

    it "does not resurrect a timer a terminal advance already deleted" do
      adapter.ordered_lock_advance(key, nonce: 1) # advances cursor, hdels nonce 1
      _next_k, _last_k, at_k = adapter.ordered_lock_keys(key)
      expect(redis.hexists(at_k, "1")).to be(false)

      expect(adapter.ordered_lock_heartbeat(key, nonce: 1, now: 1100)).to eq(0)
      expect(redis.hexists(at_k, "1")).to be(false)
    end

    it "is fenced out when the caller's epoch no longer matches (stale batch)" do
      _n, epoch = adapter.ordered_lock_assign("hbkey", now: 1000)
      # A heartbeat carrying a stale epoch must not touch the live batch.
      expect(adapter.ordered_lock_heartbeat("hbkey", nonce: 1, epoch: epoch + 99, now: 1050)).to eq(0)
    end
  end

  describe "#ordered_lock_skip hardening" do
    it "is a no-op on a fully drained batch (does not resurrect a TTL-less cursor)" do
      adapter.ordered_lock_assign(key)
      adapter.ordered_lock_advance(key, nonce: 1) # drains -> GC
      expect(key).to be_ordered_lock_drained

      expect(adapter.ordered_lock_skip(key, nonce: 1)).to eq(0)
      expect(key).to be_ordered_lock_drained
    end

    it "preserves the sequence TTL when forcing the cursor forward (KEEPTTL)" do
      adapter.ordered_lock_assign(key, ttl: 120)
      adapter.ordered_lock_assign(key, ttl: 120)
      _next_k, last_k = adapter.ordered_lock_keys(key)

      adapter.ordered_lock_skip(key, nonce: 1)
      # Plain SET would drop the TTL to -1 (persist), leaking the key forever for
      # a sequence that never drains.
      expect(redis.ttl(last_k)).to be > 0
    end
  end

  describe "#ordered_lock_advance" do
    before { 3.times { adapter.ordered_lock_assign(key) } }

    it "moves last_completed forward when own nonce == last + 1" do
      expect(adapter.ordered_lock_advance(key, nonce: 1)).to eq(1)
      expect(adapter.ordered_lock_peek(key)[:last_completed]).to eq(1)
    end

    it "is a no-op for out-of-order advance" do
      expect(adapter.ordered_lock_advance(key, nonce: 2)).to eq(0)
      expect(adapter.ordered_lock_peek(key)[:last_completed]).to eq(0)
    end

    it "garbage-collects counters when fully drained" do
      adapter.ordered_lock_advance(key, nonce: 1)
      adapter.ordered_lock_advance(key, nonce: 2)
      adapter.ordered_lock_advance(key, nonce: 3)
      expect(adapter.ordered_lock_peek(key)).to eq(next: 0, last_completed: 0, in_flight: [], first_failed: 0)
    end

    it "restarts at 1 after a full drain" do
      3.times.each { |i| adapter.ordered_lock_advance(key, nonce: i + 1) }
      n, = adapter.ordered_lock_assign(key)
      expect(n).to eq(1)
    end

    it "bumps the epoch when a fresh batch starts after a full drain" do
      # `before` assigned nonces 1-3 as generation 1. Drain them fully, then a
      # new assign restarts numbering at 1 under a new generation.
      3.times.each { |i| adapter.ordered_lock_advance(key, nonce: i + 1) }
      _n, epoch = adapter.ordered_lock_assign(key)
      expect(epoch).to eq(2)
    end
  end

  describe "#ordered_lock_skip" do
    before { 2.times { adapter.ordered_lock_assign(key) } }

    it "forces last_completed past the given nonce" do
      adapter.ordered_lock_skip(key, nonce: 1)
      expect(adapter.ordered_lock_peek(key)[:last_completed]).to eq(1)
    end
  end

  describe "#ordered_lock_advance with failed:" do
    before { 3.times { adapter.ordered_lock_assign(key) } }

    it "records the first failed nonce as the chain poison marker" do
      adapter.ordered_lock_advance(key, nonce: 1, failed: true)
      expect(adapter.ordered_lock_peek(key)[:first_failed]).to eq(1)
    end

    it "keeps only the FIRST failed nonce (later failures don't overwrite)" do
      adapter.ordered_lock_advance(key, nonce: 1, failed: true)
      adapter.ordered_lock_advance(key, nonce: 2, failed: true)
      expect(adapter.ordered_lock_peek(key)[:first_failed]).to eq(1)
    end

    it "leaves first_failed at 0 on a successful advance" do
      adapter.ordered_lock_advance(key, nonce: 1, failed: false)
      expect(adapter.ordered_lock_peek(key)[:first_failed]).to eq(0)
    end

    it "clears the marker on full drain" do
      adapter.ordered_lock_advance(key, nonce: 1, failed: true)
      adapter.ordered_lock_advance(key, nonce: 2)
      adapter.ordered_lock_advance(key, nonce: 3)
      expect(adapter.ordered_lock_peek(key)[:first_failed]).to eq(0)
    end

    it "surfaces first_failed in can_proceed responses" do
      adapter.ordered_lock_advance(key, nonce: 1, failed: true)
      _state, _retry, _last, first_failed = adapter.ordered_lock_can_proceed(
        key, nonce: 2, poison_pill_timeout: 60
      )
      expect(first_failed).to eq(1)
    end

    it "records first_failed for an out-of-order (ahead-of-cursor) failure" do
      # Nonce 2 reaches a terminal Failure while the cursor is still at 0
      # (my=2 != last+1). The no-op advance branch must still poison the chain;
      # previously this failure was silently dropped.
      adapter.ordered_lock_advance(key, nonce: 2, failed: true)
      expect(adapter.ordered_lock_peek(key)[:first_failed]).to eq(2)
    end

    it "ignores a stale/duplicate failure behind the cursor (my <= last)" do
      adapter.ordered_lock_advance(key, nonce: 1) # last_completed = 1
      # A duplicate job for already-completed nonce 1 re-runs and fails; it must
      # not poison successors that may already have run.
      adapter.ordered_lock_advance(key, nonce: 1, failed: true)
      expect(adapter.ordered_lock_peek(key)[:first_failed]).to eq(0)
    end
  end

  describe "missing assigned_at timer (poison-loop robustness)" do
    before { 2.times { adapter.ordered_lock_assign(key, now: 1000) } }

    it "advances past a blocker whose assigned_at entry is gone instead of stalling" do
      _next_k, _last_k, at_k = adapter.ordered_lock_keys(key)
      # Simulate nonce 1's timer being deleted (out-of-order advance hdel, or the
      # assigned_at hash expiring). The gate must not treat a missing timer as a
      # live blocker and wait forever.
      redis.hdel(at_k, "1")

      state, _retry, last = adapter.ordered_lock_can_proceed(
        key, nonce: 2, poison_pill_timeout: 60, now: 1010
      )
      expect(state).to eq("poison_advance")
      expect(last).to eq(1)
    end
  end

  describe "advance GC guard when next_key is missing" do
    before { 2.times { adapter.ordered_lock_assign(key) } }

    it "does not wipe live counters when next_key has expired" do
      next_k, = adapter.ordered_lock_keys(key)
      redis.del(next_k) # simulate next_key TTL expiry mid-sequence

      adapter.ordered_lock_advance(key, nonce: 1) # in-order advance, nxt reads 0
      # Without the `nxt > 0` guard, `last >= 0` would GC everything back to 0.
      expect(adapter.ordered_lock_peek(key)[:last_completed]).to eq(1)
    end
  end

  describe "stale-batch fence (cross-batch nonce reuse)" do
    # Reproduces the residual: a straggler from a drained batch whose nonce
    # number the next batch reused must not touch the new batch.
    def drain_first_batch
      n1, e1 = adapter.ordered_lock_assign(key) # batch A, nonce 1, epoch 1
      adapter.ordered_lock_advance(key, nonce: n1, epoch: e1) # drains -> GC (epoch kept)
      e1
    end

    it "ignores an advance carrying a drained batch's epoch (no corruption)" do
      stale_epoch = drain_first_batch
      # Batch B assigns two nonces so a corrupting advance can't be masked by an
      # immediate full-drain GC.
      n2, e2 = adapter.ordered_lock_assign(key) # batch B reuses nonce 1
      adapter.ordered_lock_assign(key)          # batch B nonce 2
      expect([n2, e2]).to eq([1, 2])

      # Batch A's straggler completes late with the OLD epoch.
      adapter.ordered_lock_advance(key, nonce: 1, epoch: stale_epoch)

      # Batch B is entirely untouched — cursor at 0, both nonces still in flight.
      expect(adapter.ordered_lock_peek(key)).to eq(
        next: 2, last_completed: 0, in_flight: [1, 2], first_failed: 0
      )
    end

    it "reports a drained batch's gate check as stale" do
      stale_epoch = drain_first_batch
      adapter.ordered_lock_assign(key) # batch B, epoch 2

      state, = adapter.ordered_lock_can_proceed(
        key, nonce: 1, poison_pill_timeout: 60, epoch: stale_epoch
      )
      expect(state).to eq("stale")
    end

    it "does not fence a legacy caller that carries no epoch (epoch 0)" do
      adapter.ordered_lock_assign(key) # epoch 1 in redis
      # An in-flight job from before the epoch field existed passes epoch 0.
      state, = adapter.ordered_lock_can_proceed(key, nonce: 1, poison_pill_timeout: 60)
      expect(state).to eq("go")
    end
  end

  describe "drained-batch fence (post-GC straggler, SAME epoch)" do
    # The epoch fence only fires once the next batch's first assign bumps the
    # generation. A poison-passed straggler that wakes in the window BETWEEN
    # the drain-GC and that next assign carries the still-current epoch, so it
    # bypasses the stale fence. Pre-fix, its gate's poison loop (and an
    # in-order advance) recreated last_completed — TTL-less — letting every
    # nonce of the next batch gate straight through with no ordering.
    def drain_via_poison_past_nonce2
      3.times { adapter.ordered_lock_assign(key, now: 1000) } # nonces 1-3, epoch 1
      adapter.ordered_lock_advance(key, nonce: 1, epoch: 1)
      # Nonce 2 stalls; nonce 3's gate poison-advances past it and proceeds.
      state, = adapter.ordered_lock_can_proceed(
        key, nonce: 3, poison_pill_timeout: 60, epoch: 1, now: 1100
      )
      expect(state).to eq("poison_advance")
      adapter.ordered_lock_advance(key, nonce: 3, epoch: 1) # last == next -> GC
      expect(key).to be_ordered_lock_drained
    end

    it "lets the straggler's gate go WITHOUT resurrecting last_completed" do
      drain_via_poison_past_nonce2

      state, = adapter.ordered_lock_can_proceed(
        key, nonce: 2, poison_pill_timeout: 60, epoch: 1, now: 1200
      )

      # 'drained_go' (not plain 'go'): the executor uses this to distinguish a
      # genuine late straggler (runs) from a redelivery of an already-terminal
      # context (skips). Either way the counters must not be recreated.
      expect(state).to eq("drained_go") # poison semantics: skipped jobs may run late
      expect(key).to be_ordered_lock_drained # no counters recreated
    end

    it "makes the straggler's advance a complete no-op" do
      drain_via_poison_past_nonce2

      adapter.ordered_lock_advance(key, nonce: 2, epoch: 1)

      expect(key).to be_ordered_lock_drained
    end

    it "fences an in-order (nonce 1) straggler advance — the direct ADVANCE resurrection vector" do
      # Nonce 1 itself is the poison-passed straggler. Post-GC last reads 0, so
      # its late advance satisfies `my == last + 1` and pre-fix wrote
      # last_completed = 1 with no TTL, un-gating nonce 2 of the next batch.
      2.times { adapter.ordered_lock_assign(key, now: 1000) } # nonces 1-2, epoch 1
      state, = adapter.ordered_lock_can_proceed(
        key, nonce: 2, poison_pill_timeout: 60, epoch: 1, now: 1100
      )
      expect(state).to eq("poison_advance")
      adapter.ordered_lock_advance(key, nonce: 2, epoch: 1) # last == next -> GC
      expect(key).to be_ordered_lock_drained

      adapter.ordered_lock_advance(key, nonce: 1, epoch: 1) # straggler completes late

      expect(key).to be_ordered_lock_drained
    end

    it "ignores a failed straggler's poison marker (must not strict-poison the next batch)" do
      drain_via_poison_past_nonce2

      adapter.ordered_lock_advance(key, nonce: 2, epoch: 1, failed: true)
      adapter.ordered_lock_assign(key) # next batch starts

      expect(adapter.ordered_lock_peek(key)[:first_failed]).to eq(0)
    end

    it "keeps the next batch fully ordered after a straggler gate + advance" do
      drain_via_poison_past_nonce2

      # Straggler does both: gate check, run, terminal advance.
      adapter.ordered_lock_can_proceed(key, nonce: 2, poison_pill_timeout: 60, epoch: 1, now: 1200)
      adapter.ordered_lock_advance(key, nonce: 2, epoch: 1)

      # Next batch: nonce 2 must WAIT on nonce 1 (pre-fix both gated 'go'
      # because last_completed had been resurrected to 2).
      n1, e2 = adapter.ordered_lock_assign(key, now: 1300)
      n2, = adapter.ordered_lock_assign(key, now: 1300)
      expect([n1, n2]).to eq([1, 2])

      state1, = adapter.ordered_lock_can_proceed(
        key, nonce: 1, poison_pill_timeout: 60, epoch: e2, now: 1310
      )
      state2, = adapter.ordered_lock_can_proceed(
        key, nonce: 2, poison_pill_timeout: 60, epoch: e2, now: 1310
      )
      expect(state1).to eq("go")
      expect(state2).to eq("wait")
      expect(adapter.ordered_lock_peek(key)[:last_completed]).to eq(0)
    end
  end

  describe "TTL preservation on advance (KEEPTTL)" do
    it "keeps the last_completed TTL after an advance instead of stripping it" do
      adapter.ordered_lock_assign(key, ttl: 120)
      adapter.ordered_lock_assign(key, ttl: 120)
      _next_k, last_k = adapter.ordered_lock_keys(key)

      adapter.ordered_lock_advance(key, nonce: 1)
      # `set last_key, my` without KEEPTTL would drop the TTL to -1 (persist).
      expect(redis.ttl(last_k)).to be > 0
    end
  end
end
