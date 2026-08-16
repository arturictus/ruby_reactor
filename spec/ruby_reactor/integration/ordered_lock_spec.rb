# frozen_string_literal: true

require "spec_helper"
require_relative "../../examples/locking_reactors"

RSpec.describe "OrderedLock Integration" do
  let(:adapter) { RubyReactor.configuration.storage_adapter }

  describe "nonce assignment" do
    it "assigns nonces in caller order" do
      3.times { |i| OrderedReactor.run(account_id: 1, thing: i + 1) }

      state = adapter.ordered_lock_peek("orders:1")
      expect(state[:next]).to eq(3)
      expect(state[:in_flight]).to eq([1, 2, 3])
    end

    it "scopes per key" do
      OrderedReactor.run(account_id: 1, thing: :a)
      OrderedReactor.run(account_id: 2, thing: :b)
      expect(adapter.ordered_lock_peek("orders:1")[:next]).to eq(1)
      expect(adapter.ordered_lock_peek("orders:2")[:next]).to eq(1)
    end

    it "persists the nonce on the context" do
      OrderedReactor.run(account_id: 1, thing: 42)
      jobs = Sidekiq::Queues[RubyReactor.configuration.sidekiq_queue.to_s]
      # Identity-only payload: args are [context_id, reactor_class_name]; the
      # persisted context lives in storage.
      context_id, reactor_name = jobs.first["args"]
      data = adapter.retrieve_context(context_id, reactor_name)
      ol = data["private_data"]["ordered_lock"]
      expect(ol["key"]).to eq("orders:1")
      expect(ol["nonce"]).to eq(1)
    end
  end

  describe "ordering enforcement" do
    it "snoozes a job whose nonce is ahead of last_completed + 1" do
      RubyReactor.configuration.lock_snooze_base_delay = 0.01
      RubyReactor.configuration.lock_snooze_jitter = 0

      OrderedReactor.run(account_id: 9, thing: :first)  # nonce 1
      OrderedReactor.run(account_id: 9, thing: :second) # nonce 2
      OrderedReactor.run(account_id: 9, thing: :third)  # nonce 3

      # Pop nonce 3 alone and execute it one time directly. With nonces 1+2
      # not yet drained, the gate must reject — :third must not run and a new
      # snooze must be queued. Note: WaitError bypasses lock_snooze_max_attempts,
      # so we drive perform manually rather than using `drain` (which would
      # loop until poison_pill_timeout elapses).
      third = RubyReactor::Adapters::Sidekiq::Worker.jobs.last
      RubyReactor::Adapters::Sidekiq::Worker.jobs.clear

      allow(RubyReactor::Adapters::Sidekiq::Worker).to receive(:perform_in).and_call_original
      RubyReactor::Adapters::Sidekiq::Worker.new.perform(*third["args"])

      expect(OrderedLockCounters.runs).to be_empty
      expect(adapter.ordered_lock_peek("orders:9")[:last_completed]).to eq(0)
      expect(RubyReactor::Adapters::Sidekiq::Worker).to have_received(:perform_in)
    end

    it "snoozes a waiting nonce at the base delay, not the poison-pill window" do
      # Regression: the WaitError carries a poison-pill-derived `retry_after`
      # (here ~60s). It must NOT be used as the re-poll interval — a live
      # blocker finishes in milliseconds, so the successor has to re-poll fast.
      RubyReactor.configuration.lock_snooze_base_delay = 0.01
      RubyReactor.configuration.lock_snooze_jitter = 0

      OrderedReactor.run(account_id: 11, thing: :first)  # nonce 1
      OrderedReactor.run(account_id: 11, thing: :second) # nonce 2

      second = RubyReactor::Adapters::Sidekiq::Worker.jobs.last
      RubyReactor::Adapters::Sidekiq::Worker.jobs.clear

      delays = []
      allow(RubyReactor::Adapters::Sidekiq::Worker).to receive(:perform_in) do |delay, *_|
        delays << delay
      end
      RubyReactor::Adapters::Sidekiq::Worker.new.perform(*second["args"])

      expect(delays).to contain_exactly(0.01)
    end

    it "executes in nonce order when drained in submission order" do
      OrderedReactor.run(account_id: 7, thing: 1)
      OrderedReactor.run(account_id: 7, thing: 2)
      OrderedReactor.run(account_id: 7, thing: 3)

      # The fake queue preserves enqueue order. Drain in order:
      RubyReactor.configuration.lock_snooze_base_delay = 0.01
      RubyReactor.configuration.lock_snooze_jitter = 0
      RubyReactor::Adapters::Sidekiq::Worker.drain

      expect(OrderedLockCounters.runs).to eq([1, 2, 3])
    end

    it "does not re-execute a drained-batch redelivery of an already-completed context" do
      RubyReactor.configuration.lock_snooze_base_delay = 0.01
      RubyReactor.configuration.lock_snooze_jitter = 0

      OrderedReactor.run(account_id: 21, thing: :only) # nonce 1, lone batch
      job = RubyReactor::Adapters::Sidekiq::Worker.jobs.last
      RubyReactor::Adapters::Sidekiq::Worker.drain

      expect(OrderedLockCounters.runs).to eq([:only])
      expect(adapter.ordered_lock_peek("orders:21")).to be_ordered_lock_drained

      # Re-deliver the SAME job (Sidekiq at-least-once). The gate sees a drained
      # batch (counters GC'd) -> :drained_go, but the stored context already
      # reached :completed, so this must be skipped — NOT re-run — and must not
      # clobber the terminal record.
      context_id = job["args"].first # identity-only payload: args.first IS the id
      RubyReactor::Adapters::Sidekiq::Worker.new.perform(*job["args"])

      expect(OrderedLockCounters.runs).to eq([:only]) # step did not run again
      expect(OrderedReactor.find(context_id).context.status.to_s).to eq("completed")
      expect(adapter.ordered_lock_peek("orders:21")).to be_ordered_lock_drained
    end
  end

  describe "running-blocker heartbeat" do
    it "restamps assigned_at while a slow step runs so it is not poison-passed" do
      # The step sleeps 1.3s > the 1.0s heartbeat interval (pp 3 / 3), so the
      # background thread must fire at least one restamp during execution.
      allow(adapter).to receive(:ordered_lock_heartbeat).and_call_original

      HeartbeatOrderedReactor.run(account_id: 1)

      expect(adapter).to have_received(:ordered_lock_heartbeat).at_least(:once)
    end
  end

  describe "strict mode (default: true)" do
    before do
      RubyReactor.configuration.lock_snooze_base_delay = 0.01
      RubyReactor.configuration.lock_snooze_jitter = 0
    end

    it "skips subsequent nonces with Skipped after a Failure" do
      StrictOrderedReactor.run(account_id: 1, thing: :one, fail: true)
      StrictOrderedReactor.run(account_id: 1, thing: :two)
      StrictOrderedReactor.run(account_id: 1, thing: :three)

      RubyReactor::Adapters::Sidekiq::Worker.drain

      expect(OrderedLockCounters.runs).to eq([:one])
      expect(adapter.ordered_lock_peek("strict:1")).to be_ordered_lock_drained
    end

    it "records the first failed nonce as the poison marker" do
      StrictOrderedReactor.run(account_id: 2, thing: :one, fail: true)
      StrictOrderedReactor.run(account_id: 2, thing: :two)

      first_job = RubyReactor::Adapters::Sidekiq::Worker.jobs.first
      RubyReactor::Adapters::Sidekiq::Worker.jobs.shift
      RubyReactor::Adapters::Sidekiq::Worker.new.perform(*first_job["args"])

      expect(adapter.ordered_lock_peek("strict:2")[:first_failed]).to eq(1)
    end

    it "drains the marker after a full batch completes (strict skips advance the cursor)" do
      StrictOrderedReactor.run(account_id: 3, thing: :one, fail: true)
      StrictOrderedReactor.run(account_id: 3, thing: :two)
      RubyReactor::Adapters::Sidekiq::Worker.drain

      # Sequence drained; a fresh assign should start at 1 (counters GC'd).
      n, = adapter.ordered_lock_assign("strict:3")
      expect(n).to eq(1)
    end
  end

  describe "strict: false" do
    before do
      RubyReactor.configuration.lock_snooze_base_delay = 0.01
      RubyReactor.configuration.lock_snooze_jitter = 0
    end

    it "continues running subsequent nonces in order even after a Failure" do
      NonStrictOrderedReactor.run(account_id: 1, thing: :one, fail: true)
      NonStrictOrderedReactor.run(account_id: 1, thing: :two)
      NonStrictOrderedReactor.run(account_id: 1, thing: :three)

      RubyReactor::Adapters::Sidekiq::Worker.drain

      expect(OrderedLockCounters.runs).to eq(%i[one two three])
    end

    it "still records first_failed (callers can observe it) but does not gate on it" do
      NonStrictOrderedReactor.run(account_id: 2, thing: :one, fail: true)
      NonStrictOrderedReactor.run(account_id: 2, thing: :two)

      first_job = RubyReactor::Adapters::Sidekiq::Worker.jobs.first
      RubyReactor::Adapters::Sidekiq::Worker.jobs.shift
      RubyReactor::Adapters::Sidekiq::Worker.new.perform(*first_job["args"])

      expect(adapter.ordered_lock_peek("lenient:2")[:first_failed]).to eq(1)

      # Now run nonce 2 — it should NOT be skipped despite first_failed > 0.
      second_job = RubyReactor::Adapters::Sidekiq::Worker.jobs.first
      RubyReactor::Adapters::Sidekiq::Worker.jobs.clear
      RubyReactor::Adapters::Sidekiq::Worker.new.perform(*second_job["args"])

      expect(OrderedLockCounters.runs).to eq(%i[one two])
    end
  end

  describe "drain + reset" do
    it "restarts at nonce 1 after a full drain" do
      2.times { |i| OrderedReactor.run(account_id: 5, thing: i + 1) }
      RubyReactor::Adapters::Sidekiq::Worker.drain

      n, = adapter.ordered_lock_assign("orders:5")
      expect(n).to eq(1)
    end
  end

  describe "synchronous (non-async) reactor" do
    # active_keys is a thread-local stack, not reset by the Redis flush between
    # examples; clear it so a leak from one example can't mask another.
    before { RubyReactor::Executor::OrderedLockSupport.active_keys.clear }

    it "advances the cursor and pops the active key on the sync execute path" do
      result = SyncOrderedReactor.run(account_id: 1, thing: :a)

      expect(result).to be_success
      expect(OrderedLockCounters.runs).to eq([:a])
      # leave_ordered_lock_scope must run in execute's ensure: without it the
      # cursor never advances (last_completed stuck at 0, nonce 1 stranded
      # in_flight) and the active key is never popped.
      expect(adapter.ordered_lock_peek("sync_orders:1")).to be_ordered_lock_drained
      expect(RubyReactor::Executor::OrderedLockSupport.active_keys).to be_empty
    end

    it "does not leak the active key, so a later run on the same key is still enforced" do
      SyncOrderedReactor.run(account_id: 2, thing: :first)
      SyncOrderedReactor.run(account_id: 2, thing: :second)

      expect(OrderedLockCounters.runs).to eq(%i[first second])
      # A leaked active key would make the second run skip nonce assignment and
      # silently run without ordering enforcement.
      expect(RubyReactor::Executor::OrderedLockSupport.active_keys).to be_empty
      expect(adapter.ordered_lock_peek("sync_orders:2")).to be_ordered_lock_drained
    end
  end

  describe "stale straggler (cross-batch nonce reuse)" do
    it "skips a straggler from a drained batch without corrupting the new batch" do
      RubyReactor.configuration.lock_snooze_base_delay = 0.01
      RubyReactor.configuration.lock_snooze_jitter = 0

      # Batch A: a single nonce, run to completion so the key fully drains
      # (counters GC'd, generation epoch kept).
      OrderedReactor.run(account_id: 77, thing: :a)
      straggler = RubyReactor::Adapters::Sidekiq::Worker.jobs.last
      RubyReactor::Adapters::Sidekiq::Worker.drain
      expect(adapter.ordered_lock_peek("orders:77")).to be_ordered_lock_drained

      # Batch B reuses nonce 1 under a NEW epoch; leave its job queued.
      OrderedReactor.run(account_id: 77, thing: :b)
      expect(adapter.ordered_lock_peek("orders:77")[:next]).to eq(1)
      OrderedLockCounters.runs.clear

      # Replay batch A's straggler (same serialized context -> stale epoch).
      RubyReactor::Adapters::Sidekiq::Worker.new.perform(*straggler["args"])

      # It must neither run its step nor advance batch B's cursor.
      expect(OrderedLockCounters.runs).to be_empty
      expect(adapter.ordered_lock_peek("orders:77")[:last_completed]).to eq(0)
    end

    it "ignores a duplicate delivery arriving AFTER the drain but BEFORE the next batch" do
      RubyReactor.configuration.lock_snooze_base_delay = 0.01
      RubyReactor.configuration.lock_snooze_jitter = 0

      # Batch A: single nonce, run to completion (counters GC'd, epoch kept).
      OrderedReactor.run(account_id: 78, thing: :a)
      duplicate = RubyReactor::Adapters::Sidekiq::Worker.jobs.last
      RubyReactor::Adapters::Sidekiq::Worker.drain
      expect(adapter.ordered_lock_peek("orders:78")).to be_ordered_lock_drained

      # Sidekiq at-least-once redelivery of nonce 1 in the drain->next-batch
      # window: SAME epoch, so the stale-batch fence cannot catch it. Its
      # terminal advance (my == last + 1 against the GC'd cursor) must not
      # resurrect last_completed.
      RubyReactor::Adapters::Sidekiq::Worker.new.perform(*duplicate["args"])
      expect(adapter.ordered_lock_peek("orders:78")[:last_completed]).to eq(0)

      # Batch B: nonce 2 alone must still snooze behind nonce 1 (pre-fix the
      # resurrected cursor let it gate straight through and run out of order).
      OrderedReactor.run(account_id: 78, thing: :b1) # nonce 1
      OrderedReactor.run(account_id: 78, thing: :b2) # nonce 2
      OrderedLockCounters.runs.clear

      second = RubyReactor::Adapters::Sidekiq::Worker.jobs.last
      RubyReactor::Adapters::Sidekiq::Worker.jobs.clear
      allow(RubyReactor::Adapters::Sidekiq::Worker).to receive(:perform_in).and_call_original
      RubyReactor::Adapters::Sidekiq::Worker.new.perform(*second["args"])

      expect(OrderedLockCounters.runs).to be_empty
      expect(RubyReactor::Adapters::Sidekiq::Worker).to have_received(:perform_in)
    end

    it "does not downgrade an already-completed context when a stale duplicate is redelivered" do
      RubyReactor.configuration.lock_snooze_base_delay = 0.01
      RubyReactor.configuration.lock_snooze_jitter = 0

      OrderedReactor.run(account_id: 88, thing: :a)
      duplicate = RubyReactor::Adapters::Sidekiq::Worker.jobs.last
      ctx_id = duplicate["args"].first # identity-only payload: args.first IS the id
      RubyReactor::Adapters::Sidekiq::Worker.drain
      expect(adapter.retrieve_context(ctx_id, "OrderedReactor")["status"]).to eq("completed")

      # New batch bumps the epoch, so the duplicate's gate resolves to stale.
      OrderedReactor.run(account_id: 88, thing: :b)

      # Redeliver the completed job. Its stale-batch short-circuit must NOT
      # overwrite the stored :completed record with :skipped.
      RubyReactor::Adapters::Sidekiq::Worker.new.perform(*duplicate["args"])

      expect(adapter.retrieve_context(ctx_id, "OrderedReactor")["status"]).to eq("completed")
    end
  end

  describe "composition with with_lock" do
    it "checks ordered_lock BEFORE acquiring the exclusive lock" do
      # Pre-hold the exclusive lock so a successful ordered-gate would still
      # snooze on the lock. We assign nonces 1 and 2; nonce 2 must snooze on
      # OrderedLock (not on the held lock), proving the order.
      OrderedLockWithLockReactor.run(account_id: 1, thing: :a) # nonce 1
      OrderedLockWithLockReactor.run(account_id: 1, thing: :b) # nonce 2

      jobs = RubyReactor::Adapters::Sidekiq::Worker.jobs
      _job1 = jobs.shift
      job2 = jobs.shift

      # Put nonce 2 back; do NOT execute nonce 1. Ordered gate must reject
      # nonce 2 since last_completed == 0.
      RubyReactor::Adapters::Sidekiq::Worker.jobs.clear
      RubyReactor::Adapters::Sidekiq::Worker.jobs << job2

      RubyReactor.configuration.lock_snooze_base_delay = 0.01
      RubyReactor.configuration.lock_snooze_jitter = 0
      RubyReactor.configuration.lock_snooze_max_attempts = 2

      expect { RubyReactor::Adapters::Sidekiq::Worker.drain }.not_to raise_error

      # The lock was never acquired because the ordered gate rejected first.
      expect(adapter.lock_info("lock:combo:1")).to be_nil
    end
  end

  describe "escalation advances the cursor (no head-of-line stall)" do
    it "advances past an escalated nonce with the failure marker so strict successors skip" do
      RubyReactor.configuration.lock_snooze_base_delay = 0.01
      RubyReactor.configuration.lock_snooze_jitter = 0
      RubyReactor.configuration.lock_snooze_max_attempts = 2

      # Pre-hold the exclusive lock under a foreign owner so nonce 1 can pass the
      # ordered gate but never acquire the lock — it snoozes until the cap, then
      # escalates to a terminal Failure inside the worker (never reaching the
      # Executor ensure that would normally advance the cursor).
      held = RubyReactor::Lock.new("combo:1", owner: "someone-else", ttl: 300, auto_extend: false)
      held.acquire

      OrderedLockWithLockReactor.run(account_id: 1, thing: :one) # nonce 1
      OrderedLockWithLockReactor.run(account_id: 1, thing: :two) # nonce 2

      job1 = RubyReactor::Adapters::Sidekiq::Worker.jobs.first
      RubyReactor::Adapters::Sidekiq::Worker.jobs.clear

      # Drive nonce 1 at the cap so the next snooze escalates.
      RubyReactor::Adapters::Sidekiq::Worker.new.perform(*job1["args"].first(2), 2)

      state = adapter.ordered_lock_peek("combo:1")
      # Escalation must advance the cursor (nonce 1 no longer in flight) AND
      # record the chain poison marker — otherwise nonce 2 stalls a full
      # poison_pill_timeout and, worse, runs out of turn.
      expect(state[:last_completed]).to eq(1)
      expect(state[:first_failed]).to eq(1)
      expect(state[:in_flight]).not_to include(1)
    ensure
      held&.release
    end
  end

  describe "snooze does not emit a failed_reactor middleware event" do
    it "routes ordered-lock wait contention to :snooze_reactor, not :failed_reactor" do
      events = []
      mw = Class.new do
        define_method(:on) { |event, *_args| events << event }
      end.new

      original = RubyReactor.configuration.middlewares
      RubyReactor.configuration.middlewares = [mw]

      # nonce 1 + 2; run nonce 2's job alone — its ordered gate raises WaitError.
      OrderedReactor.run(account_id: 555, thing: :first)
      OrderedReactor.run(account_id: 555, thing: :second)
      job2 = RubyReactor::Adapters::Sidekiq::Worker.jobs.last
      RubyReactor::Adapters::Sidekiq::Worker.jobs.clear

      RubyReactor.configuration.lock_snooze_base_delay = 0.01
      RubyReactor.configuration.lock_snooze_jitter = 0
      allow(RubyReactor::Adapters::Sidekiq::Worker).to receive(:perform_in)
      RubyReactor::Adapters::Sidekiq::Worker.new.perform(*job2["args"])

      expect(events).to include(:snooze_reactor)
      expect(events).not_to include(:failed_reactor)
    ensure
      RubyReactor.configuration.middlewares = original
    end
  end

  # Our state matchers take a bare key string as their subject.
  describe "RSpec matchers" do
    let(:key) { "orders:matchers" }

    describe "have_ordered_lock_next" do
      it "matches the assigned counter" do
        adapter.ordered_lock_assign(key)
        adapter.ordered_lock_assign(key)
        expect(key).to have_ordered_lock_next(2)
      end

      it "rejects a wrong value" do
        adapter.ordered_lock_assign(key)
        expect(key).not_to have_ordered_lock_next(5)
      end
    end

    describe "have_ordered_lock_last_completed" do
      it "matches the cursor after advancing" do
        adapter.ordered_lock_assign(key)
        adapter.ordered_lock_assign(key)
        adapter.ordered_lock_advance(key, nonce: 1)
        expect(key).to have_ordered_lock_last_completed(1)
      end

      it "rejects a wrong value" do
        adapter.ordered_lock_assign(key)
        expect(key).not_to have_ordered_lock_last_completed(5)
      end
    end

    describe "have_ordered_lock_in_flight" do
      it "matches the exact set, order-insensitive" do
        3.times { adapter.ordered_lock_assign(key) }
        adapter.ordered_lock_advance(key, nonce: 1)
        expect(key).to have_ordered_lock_in_flight(3, 2)
      end

      it "rejects a mismatched set" do
        2.times { adapter.ordered_lock_assign(key) }
        expect(key).not_to have_ordered_lock_in_flight(1)
      end
    end

    describe "be_ordered_lock_drained" do
      it "matches a key with no counters" do
        expect(key).to be_ordered_lock_drained
      end

      it "matches a key after a full drain" do
        2.times { adapter.ordered_lock_assign(key) }
        adapter.ordered_lock_advance(key, nonce: 1)
        adapter.ordered_lock_advance(key, nonce: 2)
        expect(key).to be_ordered_lock_drained
      end

      it "rejects a key with in-flight nonces" do
        adapter.ordered_lock_assign(key)
        expect(key).not_to be_ordered_lock_drained
      end
    end
  end

  describe "composed children with with_ordered_lock" do
    it "warns at class-load time and does NOT assign a nonce when composed" do
      logger = RubyReactor.configuration.logger
      allow(logger).to receive(:warn)

      stub_const("ComposedOrderedChild", Class.new(RubyReactor::Reactor) do
        def self.name = "ComposedOrderedChild"
        with_ordered_lock { |_| "child:key" }
        step(:noop) { run { RubyReactor.Success(:ok) } }
      end)

      stub_const("ComposingParent", Class.new(RubyReactor::Reactor) do
        def self.name = "ComposingParent"
        compose :child_step, ComposedOrderedChild
      end)

      expect(logger).to have_received(:warn).with(
        a_string_including(
          "with_ordered_lock", "ComposedOrderedChild", "ignored", "ComposingParent", "child_step"
        )
      )

      ComposingParent.run
      expect(adapter.ordered_lock_peek("child:key")[:next]).to eq(0)
    end
  end

  describe "synchronous nested Reactor.run on same key" do
    let(:inner_runs) { [] }

    it "warns and silently skips inner nonce assignment (inner runs without ordering)" do
      logger = RubyReactor.configuration.logger
      allow(logger).to receive(:warn)
      sink = inner_runs

      inner = Class.new(RubyReactor::Reactor) do
        def self.name = "InnerOrderedReactor"
        with_ordered_lock { |inputs| "nested:#{inputs[:k]}" }
        input :k
        step(:noop) do
          run do
            sink << :inner
            RubyReactor.Success(:inner_ran)
          end
        end
      end
      stub_const("InnerOrderedReactor", inner)

      stub_const("OuterOrderedReactor", Class.new(RubyReactor::Reactor) do
        def self.name = "OuterOrderedReactor"
        with_ordered_lock { |inputs| "nested:#{inputs[:k]}" }
        input :k
        step :recurse do
          argument :k, input(:k)
          run do |args|
            InnerOrderedReactor.run(k: args[:k])
            RubyReactor.Success(:outer_done)
          end
        end
      end)

      result = OuterOrderedReactor.run(k: "abc")

      expect(result).to be_success
      expect(inner_runs).to eq([:inner])
      expect(logger).to have_received(:warn).with(
        a_string_including("nested `Reactor.run`", "InnerOrderedReactor", "nested:abc")
      )
    end

    it "allows nested Reactor.run on a DIFFERENT key without warning" do
      logger = RubyReactor.configuration.logger
      allow(logger).to receive(:warn)
      sink = inner_runs

      inner = Class.new(RubyReactor::Reactor) do
        def self.name = "InnerDifferentKeyReactor"
        with_ordered_lock { |_| "inner:different" }
        step(:noop) do
          run do
            sink << :inner
            RubyReactor.Success(:inner)
          end
        end
      end
      stub_const("InnerDifferentKeyReactor", inner)

      stub_const("OuterDifferentKeyReactor", Class.new(RubyReactor::Reactor) do
        def self.name = "OuterDifferentKeyReactor"
        with_ordered_lock { |_| "outer:key" }
        step :recurse do
          run do
            InnerDifferentKeyReactor.run
            RubyReactor.Success(:outer)
          end
        end
      end)

      result = OuterDifferentKeyReactor.run

      expect(result).to be_success
      expect(inner_runs).to eq([:inner])
      expect(logger).not_to have_received(:warn).with(a_string_including("nested `Reactor.run`"))
    end
  end

  describe "Reactor.run validation failure" do
    before do
      stub_const("InvalidOrderedReactor", Class.new(RubyReactor::Reactor) do
        def self.name = "InvalidOrderedReactor"
        async
        with_ordered_lock { |_| "validation_key" }
        input :email, validate: proc { required(:email).filled(format?: /@/) }
        step(:noop) { run { RubyReactor.Success(:ok) } }
      end)
    end

    it "does NOT assign a nonce when input validation fails" do
      result = InvalidOrderedReactor.run(email: "not-an-email")
      expect(result).to be_failure
      expect(adapter.ordered_lock_peek("validation_key")[:next]).to eq(0)
    end
  end
end
