# frozen_string_literal: true

require "spec_helper"

# US8: an inline `step :x do with_lock { } end` behaves exactly like the
# class form — the inline path is expected to work already via T007
# (StepConfig reads its OWN lock_config) + T013 (run_step_implementation
# wraps has_run_block? in StepCoordination). This spec proves it, running
# lock_spec's core scenarios against both forms from one shared example set.
RSpec.describe "step-scoped coordination: inline steps behave like class steps", :step_coordination do
  def unique_account_id
    SecureRandom.random_number(10**9)
  end

  shared_examples "step-scoped lock" do
    it "never lets two executions on the same key overlap, across 20 iterations (SC-001)" do
      run_id = step_coord_run_id
      account_id = unique_account_id

      threads = Array.new(2) do
        Thread.new do
          10.times do |i|
            sleep_for = 0.01 + ((i % 3) * 0.005)
            reactor_class.run(run_id: run_id, account_id: account_id, sleep_for: sleep_for)
          end
        end
      end
      threads.each(&:join)

      expect(overlap_recorder.max_concurrency(:charge)).to eq(1)
    end

    it "lets two executions on different keys overlap" do
      run_id = step_coord_run_id
      t1 = Thread.new { reactor_class.run(run_id: run_id, account_id: unique_account_id, sleep_for: 0.3) }
      t2 = Thread.new { reactor_class.run(run_id: run_id, account_id: unique_account_id, sleep_for: 0.3) }
      [t1, t2].each(&:join)

      expect(overlap_recorder.overlapped?(:charge, :charge)).to be(true)
    end

    it "leaves the key free once a locked step succeeds (SC-003)" do
      account_id = unique_account_id
      result = reactor_class.run(account_id: account_id)

      expect(result).to be_a(RubyReactor::Success)
      expect("acct:#{account_id}").not_to be_locked
    end

    it "leaves the key free when the step body returns a Failure" do
      account_id = unique_account_id
      result = reactor_class.run(account_id: account_id, fail_after: true)

      expect(result).to be_a(RubyReactor::Failure)
      expect("acct:#{account_id}").not_to be_locked
    end

    it "leaves the key free when the step body raises" do
      account_id = unique_account_id
      result = reactor_class.run(account_id: account_id, raise_after: true)

      expect(result).to be_a(RubyReactor::Failure)
      expect("acct:#{account_id}").not_to be_locked
    end
  end

  describe "a class-declared step" do
    let(:reactor_class) { LockedChargeReactor }

    it_behaves_like "step-scoped lock"
  end

  describe "an inline-declared step" do
    let(:reactor_class) { InlineLockedChargeReactor }

    it_behaves_like "step-scoped lock"
  end

  it "gives identical recorder shape (one enter + one leave) whether the lock is declared on a " \
     "class step or inline" do
    run_id_a = SecureRandom.uuid
    run_id_b = SecureRandom.uuid
    account_id = unique_account_id

    class_result = LockedChargeReactor.run(run_id: run_id_a, account_id: account_id, sleep_for: 0.05)
    inline_result = InlineLockedChargeReactor.run(run_id: run_id_b, account_id: account_id, sleep_for: 0.05)

    expect(class_result).to be_a(RubyReactor::Success)
    expect(inline_result).to be_a(RubyReactor::Success)
    expect(OverlapRecorder.new(run_id_a).entries(:charge).size).to eq(2)
    expect(OverlapRecorder.new(run_id_b).entries(:charge).size).to eq(2)
  end

  it "runs an inline compensate block under the step's own lock, matching the class form (US6)" do
    run_id = step_coord_run_id
    account_id = unique_account_id

    compensate_thread = Thread.new do
      InlineLockedChargeReactor.run(run_id: run_id, account_id: account_id, sleep_for: 1.0, fail_after: true)
    end

    sleep 0.3
    forward_thread = Thread.new do
      InlineLockedChargeReactor.run(run_id: run_id, account_id: account_id, sleep_for: 0.3)
    end

    [compensate_thread, forward_thread].each(&:join)

    expect(overlap_recorder.overlapped?(:charge_compensate, :charge)).to be(false)
  end
end
