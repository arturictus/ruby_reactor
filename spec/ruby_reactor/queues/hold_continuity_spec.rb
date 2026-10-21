# frozen_string_literal: true

require "spec_helper"

# 011 FR-012/FR-017, H-3 (review F1, F2): a run's reactor holds stay checked
# out across every hop — forward and during rollback — and are released when
# the run ends, including by a manual undo or a cancel of a run waiting on a hop.
RSpec.describe "holds across queue hops (US2)", type: :reactor do
  def perform_all(limit: 50)
    count = 0
    while (job = QueueProbe.next_job)
      job.perform!
      count += 1
      raise "more than #{limit} jobs" if count > limit
    end
    count
  end

  def started(reactor_class)
    test_reactor(reactor_class, {}, process_jobs: false).tap(&:run)
  end

  def run_id(subject)
    subject.reactor_instance.context.context_id
  end

  def status(klass, subject)
    klass.find(run_id(subject)).context.status.to_s
  end

  let(:lock_key) { "qfx:lock" }
  let(:semaphore) { "qfx:sem" }

  for_each_async_backend do
    describe "during a rollback that hops (F1)" do
      it "keeps the reactor's lock held while the rollback waits on another queue" do
        subject = started(QueueFixtures::MainLockedFailing)
        3.times { QueueProbe.next_job.perform! } # main, stripe, main: :third fails, rollback hops to stripe

        expect(QueueFixtures.queues_of_pending).to eq(["stripe"])
        expect(lock_key).to be_locked

        perform_all
        expect(subject).to be_failure
        expect(QueueFixtures.run_log.grep(/\Aundo:/)).to eq(%w[undo:s.two undo:s.one undo:m.second undo:m.first])
        expect(lock_key).not_to be_locked
      end

      it "keeps the reactor's semaphore slot while the rollback waits, and frees it at the end" do
        subject = started(QueueFixtures::MainSemaphoreFailing)
        3.times { QueueProbe.next_job.perform! }

        expect(semaphore).to have_held_tokens(1)

        perform_all
        expect(subject).to be_failure
        expect(semaphore).to have_available_tokens(1)
      end
    end

    describe "a run waiting on a forward hop that is undone or cancelled (F2)" do
      it "frees the semaphore slot when the run is undone" do
        subject = started(QueueFixtures::MainSemaphore)
        QueueProbe.next_job.perform! # main: hop to stripe, slot parked
        expect(semaphore).to have_held_tokens(1)

        subject.undo(process_jobs: true)
        expect(status(QueueFixtures::MainSemaphore, subject)).to eq("cancelled")
        expect(semaphore).to have_available_tokens(1)
      end

      it "frees the lock when the run is undone" do
        subject = started(QueueFixtures::MainLocked)
        QueueProbe.next_job.perform!
        expect(lock_key).to be_locked

        subject.undo(process_jobs: true)
        expect(status(QueueFixtures::MainLocked, subject)).to eq("cancelled")
        expect(lock_key).not_to be_locked
      end

      it "frees the lock and the slot when the run is cancelled" do
        locked = started(QueueFixtures::MainLocked)
        QueueProbe.next_job.perform!
        QueueFixtures::MainLocked.cancel(id: run_id(locked), reason: "no longer needed")
        expect(lock_key).not_to be_locked

        sem = started(QueueFixtures::MainSemaphore)
        QueueFixtures.jobs_on(:main).first.perform!
        QueueFixtures::MainSemaphore.cancel(id: run_id(sem), reason: "no longer needed")
        expect(semaphore).to have_available_tokens(1)
      end

      it "frees a composed child's own lock parked by a hop inside the child" do
        subject = started(QueueFixtures::MainLockedChild)
        QueueProbe.next_job.perform! # main: :second, hop to stripe
        QueueProbe.next_job.perform! # stripe: child takes its lock, :one, hops to ledger for :two
        expect(QueueFixtures.queues_of_pending).to eq(["ledger"])
        expect("qfx:child-lock").to be_locked

        subject.undo(process_jobs: true)
        expect(status(QueueFixtures::MainLockedChild, subject)).to eq("cancelled")
        expect("qfx:child-lock").not_to be_locked
      end

      it "still frees a composed child's lock on an ordinary completion" do
        subject = started(QueueFixtures::MainLockedChild)
        perform_all

        expect(subject).to be_success
        expect("qfx:child-lock").not_to be_locked
      end
    end
  end
end
