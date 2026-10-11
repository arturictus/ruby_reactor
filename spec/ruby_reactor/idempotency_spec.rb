# frozen_string_literal: true

require "spec_helper"

# 011 US6 (contracts/public-api.md "Run-level idempotency").
module IdempotencySpec
  @runs = Hash.new(0)
  @mutex = Mutex.new

  def self.ran(step) = @mutex.synchronize { @runs[step] += 1 }
  def self.runs(step) = @runs[step]
  def self.reset! = @mutex.synchronize { @runs.clear }

  class Charge < RubyReactor::Reactor
    input :order_id
    input :amount, :integer
    input :decline, optional: true

    step :charge do
      argument :amount, input(:amount)
      argument :decline, input(:decline)
      run do |args, _ctx|
        IdempotencySpec.ran(:charge)
        args.decline ? RubyReactor.Failure("card declined") : RubyReactor.Success(args.amount)
      end
    end

    returns :charge
  end

  class Refund < RubyReactor::Reactor
    input :order_id

    step :refund do
      argument :order_id, input(:order_id)
      run do |args, _ctx|
        IdempotencySpec.ran(:refund)
        RubyReactor.Success(args.order_id)
      end
    end
  end

  class Approval < RubyReactor::Reactor
    input :order_id

    step :prepare do
      argument :order_id, input(:order_id)
      run do |args, _ctx|
        IdempotencySpec.ran(:prepare)
        RubyReactor.Success(args.order_id)
      end
    end

    interrupt :approve do
      wait_for :prepare
    end
  end

  class Locked < RubyReactor::Reactor
    input :order_id
    with_lock(ttl: 30) { |inputs| "idempotency-spec:#{inputs[:order_id]}" }

    step :work do
      argument :order_id, input(:order_id)
      run do |args, _ctx|
        IdempotencySpec.ran(:locked)
        RubyReactor.Success(args.order_id)
      end
    end
  end

  class Background < RubyReactor::Reactor
    background all: true
    input :order_id

    step :work do
      argument :order_id, input(:order_id)
      run { |args, _ctx| RubyReactor.Success(args.order_id) }
    end
  end
end

RSpec.describe "Run-level idempotency keys" do
  before { IdempotencySpec.reset! }

  describe "repeating a key" do
    it "replays a completed run without running a step again, ignoring the new inputs" do
      first = IdempotencySpec::Charge.run({ order_id: 1, amount: 100 }, idempotency_key: "charge-1")
      again = IdempotencySpec::Charge.run({ order_id: 1, amount: 999 }, idempotency_key: "charge-1")

      expect(first).to be_a(RubyReactor::Success)
      expect(first.respond_to?(:idempotent_replay?)).to be(false)
      expect(again).to be_a(RubyReactor::Success)
      expect(again.value).to eq(100)
      expect(again.idempotent_replay?).to be(true)
      expect(again.execution_id).to eq(first.execution_id)
      expect(IdempotencySpec.runs(:charge)).to eq(1)
    end

    it "replays a failed run as its original Failure" do
      first = IdempotencySpec::Charge.run({ order_id: 2, amount: 5, decline: true }, idempotency_key: "charge-2")
      again = IdempotencySpec::Charge.run({ order_id: 2, amount: 5 }, idempotency_key: "charge-2")

      expect(first).to be_a(RubyReactor::Failure)
      expect(again).to be_a(RubyReactor::Failure)
      expect(again.error).to eq(first.error)
      expect(again.idempotent_replay?).to be(true)
      expect(IdempotencySpec.runs(:charge)).to eq(1)
    end

    it "replays a paused run as its interrupt result" do
      first = IdempotencySpec::Approval.run({ order_id: 3 }, idempotency_key: "approve-3")
      again = IdempotencySpec::Approval.run({ order_id: 3 }, idempotency_key: "approve-3")

      expect(first).to be_a(RubyReactor::InterruptResult)
      expect(again).to be_a(RubyReactor::InterruptResult)
      expect(again.execution_id).to eq(first.execution_id)
      expect(again.idempotent_replay?).to be(true)
      expect(IdempotencySpec.runs(:prepare)).to eq(1)
    end

    it "answers a run that is still in the background with a DispatchResult for it" do
      first = IdempotencySpec::Background.run({ order_id: 4 }, idempotency_key: "bg-4")
      again = IdempotencySpec::Background.run({ order_id: 4 }, idempotency_key: "bg-4")

      expect(first).to be_a(RubyReactor::DispatchResult)
      expect(again).to be_a(RubyReactor::DispatchResult)
      expect(again.execution_id).to eq(first.execution_id)
      expect(again.idempotent_replay?).to be(true)
    end
  end

  describe "claiming a key" do
    it "does not claim a key for inputs that fail validation" do
      invalid = IdempotencySpec::Charge.run({ order_id: 5, amount: "lots" }, idempotency_key: "charge-5")
      valid = IdempotencySpec::Charge.run({ order_id: 5, amount: 50 }, idempotency_key: "charge-5")

      expect(invalid).to be_a(RubyReactor::Failure)
      expect(valid).to be_a(RubyReactor::Success)
      expect(valid.respond_to?(:idempotent_replay?)).to be(false)
      expect(IdempotencySpec.runs(:charge)).to eq(1)
    end

    it "scopes keys per reactor class" do
      IdempotencySpec::Charge.run({ order_id: 6, amount: 1 }, idempotency_key: "order-6")
      refund = IdempotencySpec::Refund.run({ order_id: 6 }, idempotency_key: "order-6")

      expect(refund).to be_a(RubyReactor::Success)
      expect(IdempotencySpec.runs(:refund)).to eq(1)
    end

    it "runs exactly once when several callers race for the same key" do
      gate = Queue.new
      threads = Array.new(5) do
        Thread.new do
          gate.pop
          IdempotencySpec::Charge.run({ order_id: 7, amount: 70 }, idempotency_key: "charge-7")
        end
      end
      5.times { gate << true }
      results = threads.map(&:value)

      expect(IdempotencySpec.runs(:charge)).to eq(1)
      expect(results.map(&:execution_id).uniq.size).to eq(1)
      expect(results.count { |r| r.respond_to?(:idempotent_replay?) }).to eq(4)
    end

    it "still accepts braceless inputs" do
      expect(IdempotencySpec::Refund.run(order_id: 8)).to be_a(RubyReactor::Success)
      expect(IdempotencySpec::Refund.run(order_id: 9, idempotency_key: "refund-9")).to be_a(RubyReactor::Success)
      expect(IdempotencySpec::Refund.run(order_id: 9, idempotency_key: "refund-9").idempotent_replay?).to be(true)
    end
  end

  # Review F1: a claim must never outlive a run that was never saved.
  describe "a claim whose run was never saved" do
    let(:storage) { RubyReactor.configuration.storage_adapter }
    let(:refund_name) { RubyReactor.reactor_storage_name(IdempotencySpec::Refund) }

    it "is released when the first run fails before saving, so a retry runs" do
      holder = RubyReactor::Lock.new("idempotency-spec:12", owner: "elsewhere", ttl: 30, wait: 0, auto_extend: false)
      holder.acquire
      expect { IdempotencySpec::Locked.run({ order_id: 12 }, idempotency_key: "locked-12") }
        .to raise_error(RubyReactor::Lock::AcquisitionError)
      holder.release

      retried = IdempotencySpec::Locked.run({ order_id: 12 }, idempotency_key: "locked-12")

      expect(retried).to be_a(RubyReactor::Success)
      expect(retried.respond_to?(:idempotent_replay?)).to be(false)
      expect(IdempotencySpec.runs(:locked)).to eq(1)
    end

    it "is taken over when its run died before saving (no live liveness lock)" do
      storage.claim_idempotency_key("refund-13", "dead-run", refund_name)

      result = IdempotencySpec::Refund.run({ order_id: 13 }, idempotency_key: "refund-13")

      expect(result).to be_a(RubyReactor::Success)
      expect(result.respond_to?(:idempotent_replay?)).to be(false)
      expect(storage.claim_idempotency_key("refund-13", "x", refund_name)).to eq(result.execution_id)
    end

    it "is left alone while its run is alive but not saved yet" do
      storage.claim_idempotency_key("refund-14", "live-run", refund_name)
      liveness = RubyReactor::Lock.new("async:live-run", owner: "live-run", ttl: 30, wait: 0, auto_extend: false)
      liveness.acquire

      result = IdempotencySpec::Refund.run({ order_id: 14 }, idempotency_key: "refund-14")

      expect(result).to be_a(RubyReactor::DispatchResult)
      expect(result.idempotent_replay?).to be(true)
      expect(result.execution_id).to eq("live-run")
      expect(IdempotencySpec.runs(:refund)).to eq(0)
    ensure
      liveness&.release
    end
  end

  describe "retention" do
    it "forgets a key after context_ttl", redis_only: "Redis keeps keys for context_ttl" do
      original_ttl = RubyReactor.configuration.context_ttl
      RubyReactor.configuration.context_ttl = 1
      IdempotencySpec::Refund.run({ order_id: 10 }, idempotency_key: "refund-10")
      sleep 1.2

      again = IdempotencySpec::Refund.run({ order_id: 10 }, idempotency_key: "refund-10")

      expect(again.respond_to?(:idempotent_replay?)).to be(false)
      expect(IdempotencySpec.runs(:refund)).to eq(2)
    ensure
      RubyReactor.configuration.context_ttl = original_ttl
    end

    it "keeps a key forever", active_record_only: "ActiveRecord keeps history" do
      first = IdempotencySpec::Refund.run({ order_id: 11 }, idempotency_key: "refund-11")
      RubyReactor::Storage::ActiveRecordAdapter::IdempotencyKey
        .update_all(created_at: Time.current - RubyReactor.configuration.context_ttl - 60)

      again = IdempotencySpec::Refund.run({ order_id: 11 }, idempotency_key: "refund-11")

      expect(again.idempotent_replay?).to be(true)
      expect(again.execution_id).to eq(first.execution_id)
    end
  end
end
