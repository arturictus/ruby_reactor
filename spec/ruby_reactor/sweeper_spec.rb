# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyReactor::Sweeper do
  subject(:sweeper) { described_class.new(storage: storage, async_router: router) }

  let(:storage) { RubyReactor.configuration.storage_adapter }
  let(:reactor_class) { Class.new { def self.name = "SweeperTestReactor" } }
  let(:enqueued) { [] }
  let(:router) do
    captured = enqueued
    Class.new do
      define_singleton_method(:perform_async) { |id, klass| captured << [id, klass] }
    end
  end

  # Persist a context with the given status and return its id.
  def store_context(status:, parent_context_id: nil, async_dispatched: false)
    context = RubyReactor::Context.new({ n: 1 }, reactor_class)
    context.status = status
    context.current_step = :work if status == :running
    context.parent_context_id = parent_context_id
    context.private_data[:async_dispatched] = true if async_dispatched
    storage.store_context(
      context.context_id, RubyReactor::ContextSerializer.serialize(context), reactor_class.name
    )
    context.context_id
  end

  def hold_lock(context_id)
    # Mirror a live worker's per-context lock via the real Lock primitive (which
    # applies the "lock:" prefix, exactly as the executor's context lock does).
    RubyReactor::Lock.new("async:#{context_id}", owner: "live-worker", ttl: 60, auto_extend: false).acquire
  end

  describe "#run_once" do
    it "re-enqueues a running context with no live lock" do
      id = store_context(status: :running)

      expect(sweeper.run_once).to eq(1)
      expect(enqueued).to eq([[id, "SweeperTestReactor"]])
    end

    it "skips a running context whose worker still holds the lock" do
      id = store_context(status: :running)
      hold_lock(id)

      expect(sweeper.run_once).to eq(0)
      expect(enqueued).to be_empty
    end

    # 009 S-5: a rollback whose owner resume was lost.
    it "re-enqueues a rolling_back context with no live lock, and skips one with" do
      id = store_context(status: :rolling_back)
      expect(sweeper.run_once).to eq(1)
      expect(enqueued).to eq([[id, "SweeperTestReactor"]])

      hold_lock(id)
      expect(sweeper.run_once).to eq(0)
    end

    %i[completed failed halted].each do |terminal|
      it "skips a terminal (#{terminal}) context" do
        store_context(status: terminal)

        expect(sweeper.run_once).to eq(0)
        expect(enqueued).to be_empty
      end
    end

    it "re-enqueues a stranded async_reactor child" do
      # Nothing waits on a fire-and-forget child, so if its job is lost the
      # sweeper is the only thing that can ever restart it.
      id = store_context(status: :running, parent_context_id: "parent-1", async_dispatched: true)

      expect(sweeper.run_once).to eq(1)
      expect(enqueued).to eq([[id, "SweeperTestReactor"]])
    end

    it "skips a compose child, which runs inline in its parent" do
      store_context(status: :running, parent_context_id: "parent-1")

      expect(sweeper.run_once).to eq(0)
      expect(enqueued).to be_empty
    end

    it "is idempotent across back-to-back sweeps while the worker stays dead" do
      store_context(status: :running)

      first = sweeper.run_once
      second = sweeper.run_once

      # Both sweeps re-enqueue (the context is still running and unlocked); the
      # duplicate is harmless because the per-context lock serializes delivery.
      # What matters is run_once never double-counts within a single sweep.
      expect(first).to eq(1)
      expect(second).to eq(1)
      expect(enqueued.size).to eq(2)
    end

    it "purges expired coordination state (a no-op on Redis)" do
      storage.lock_acquire("lock:sweeper-expiring", "gone", 1)
      sleep 1.2
      allow(storage).to receive(:purge_expired_coordination).and_call_original

      sweeper.run_once

      expect(storage).to have_received(:purge_expired_coordination)
      if StorageSelection.active_record?
        expect(RubyReactor::Storage::ActiveRecordAdapter::CoordinationEntry.where(key: "lock:sweeper-expiring"))
          .not_to exist
      end
    end

    it "keeps sweeping when the purge fails" do
      allow(storage).to receive(:purge_expired_coordination).and_raise(StandardError, "boom")
      store_context(status: :running)

      expect(sweeper.run_once).to eq(1)
    end
  end
end
