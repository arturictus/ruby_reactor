# frozen_string_literal: true

require "spec_helper"

# 011 US2-AS8/AS9: every re-dispatch of a run working inside a composed child —
# a background interrupt resume, a retry, a snooze on contention — stays on the
# child's queue.
RSpec.describe "re-dispatches inside a composed child (US2)", type: :reactor do
  def perform_all(limit: 50)
    count = 0
    while (job = QueueProbe.next_job)
      job.perform!
      count += 1
      raise "more than #{limit} jobs" if count > limit
    end
    count
  end

  def started(reactor_class, inputs = {})
    test_reactor(reactor_class, inputs, process_jobs: false).tap(&:run)
  end

  before do
    stub_const("LockedStripe", Class.new(RollbackRecorder::Reactor) do
      tag "s"
      queue :stripe
      with_lock { |_inputs| "qfx:child-lock" }
      input :prev, optional: true
      recording_step :one
    end)
    stub_const("MainLockedChild", Class.new(RollbackRecorder::Reactor) do
      tag "m"
      queue :main
      recording_step :first
      compose(:deposit, LockedStripe) { argument :prev, result(:first) }
      background after: :first
    end)
  end

  for_each_async_backend do
    it "resumes a background interrupt in the child on the child's queue (AS8)" do
      subject = started(QueueFixtures::MainApproval)
      perform_all
      id = subject.reactor_instance.context.context_id
      expect(QueueFixtures::MainApproval.find(id).context.status.to_s).to eq("paused")

      QueueFixtures::MainApproval.continue(id: id, payload: { ok: true }, step_name: %i[deposit approve])
      expect(QueueFixtures.queues_of_pending).to eq(["stripe"])

      perform_all
      expect(subject).to be_success
      expect(subject.composed(:deposit)).to have_run_step(:two).on_queue(:stripe)
      expect(subject).to have_run_step(:last).on_queue(:main)
    end

    it "requeues a retry in the child on the child's queue (AS9)" do
      subject = started(QueueFixtures::MainRetry)
      QueueProbe.next_job.perform!

      expect(QueueFixtures.count("run:s.one")).to eq(1)
      expect(QueueFixtures.queues_of_pending).to eq(["stripe"])

      perform_all
      expect(subject).to be_success
      expect(QueueFixtures.count("run:s.one")).to eq(2)
    end

    it "snoozes on the child's queue while the child's lock is busy" do
      subject = started(MainLockedChild)

      hold_lock("qfx:child-lock") { QueueProbe.next_job.perform! }
      expect(QueueFixtures.queues_of_pending).to eq(["stripe"])

      perform_all
      expect(subject).to be_success
      expect(subject.composed(:deposit)).to have_run_step(:one).on_queue(:stripe)
    end
  end
end
