require "rails_helper"

RSpec.describe StepLockDemoReactor, type: :reactor do
  before { StepLockDemoLog.reset! }

  # `drain_async_jobs` (shipped, sequential) would never let a second run
  # actually contend the first's lock — this reactor is `background all:
  # true`, so BOTH runs are queued jobs, and draining them one at a time
  # means the first always finishes (releasing the lock) before the second
  # starts. `pending_async_jobs` (also shipped) hands back performable job
  # wrappers instead of draining them itself, so real Ruby threads can run
  # whatever is currently queued concurrently — genuine contention against
  # the same real Redis lock — with any re-queued park forming the next
  # wave.
  def run_concurrently!
    loop do
      jobs = pending_async_jobs
      break if jobs.empty?

      jobs.map { |job| Thread.new { job.perform! } }.each(&:join)
    end
  end

  describe "happy path" do
    it "runs :audit, then the locked :charge, then :notify, releasing the lock" do
      account_id = "acct_#{SecureRandom.hex(4)}"

      # A single dispatch, no contention to arrange — the default
      # `process_jobs: true` (sequential drain) is all this needs.
      subject = test_reactor(described_class, { account_id: account_id })

      expect(subject).to be_success
      expect(subject).to have_run_step(:notify).after(:charge)
      expect("demo:acct:#{account_id}").not_to be_locked
    end
  end

  describe "contention" do
    it "parks the loser in the worker instead of failing it, and both complete" do
      account_id = "acct_#{SecureRandom.hex(4)}"

      s1 = test_reactor(described_class, { account_id: account_id }, process_jobs: false)
      s2 = test_reactor(described_class, { account_id: account_id }, process_jobs: false)
      s1.run
      s2.run
      run_concurrently!

      r1 = described_class.find(s1.reactor_instance.context.context_id)
      r2 = described_class.find(s2.reactor_instance.context.context_id)

      expect(r1.context.status.to_s).to eq("completed")
      expect(r2.context.status.to_s).to eq("completed")

      contended = [r1, r2].select do |r|
        r.context.execution_trace.any? { |e| e[:type].to_s == "contention_park" }
      end
      expect(contended.size).to eq(1), "expected exactly one of the two runs to have parked on contention"
      expect(contended.first).to have_contended_at(:charge)
    end
  end

  describe "compensation" do
    it "rolls :charge back under its own lock when a later step fails (fail_after_charge)" do
      account_id = "acct_#{SecureRandom.hex(4)}"

      subject = test_reactor(described_class, { account_id: account_id, fail_after_charge: true })

      expect(subject).to be_failure
      expect(StepLockDemoLog.entries).to include(hash_including(step: :charge, phase: :undo))
      expect("demo:acct:#{account_id}").not_to be_locked
    end
  end

  describe "direct step invocation" do
    it "contends with an externally-held key, wait-then-fail (dsl-surface §3)" do
      account_id = "acct_#{SecureRandom.hex(4)}"
      key = "demo:acct:#{account_id}"

      # A direct `Step.run` call has no StepExecutor around it to turn a
      # contention raise into a Failure result — it raises, naming the
      # primitive, key, and step (dsl-surface.md §3/§7).
      hold_lock(key) do
        expect do
          StepLockChargeStep.run({ account_id: account_id }, nil)
        end.to raise_error(RubyReactor::Executor::StepCoordination::Contended, /demo:acct:#{account_id}/)
      end

      expect(key).not_to be_locked
    end
  end
end
