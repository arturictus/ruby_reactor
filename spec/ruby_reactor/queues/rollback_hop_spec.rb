# frozen_string_literal: true

require "spec_helper"

# 011 US2-AS6, P-3, H-6, H-9: a failure after hops compensates the failing step
# where it failed, then undoes each completed unit on its own queue, hopping
# in rollback order; every undo runs once.
RSpec.describe "rollback across queues (US2)", type: :reactor do
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

  def trace_entry(subject, type, step)
    subject.reactor_instance.context.execution_trace.find do |entry|
      entry[:type].to_s == type && entry[:step].to_s == step
    end
  end

  for_each_async_backend do
    it "compensates where the step failed and undoes each unit on its own queue (AS6)" do
      subject = started(QueueFixtures::MainFailing)
      perform_all

      expect(subject).to be_failure
      expect(QueueFixtures.run_log).to eq(
        %w[run:m.first run:m.second run:s.one run:s.two run:m.third
           compensate:m.third undo:s.two undo:s.one undo:m.second undo:m.first]
      )
      expect(trace_entry(subject, "compensate", "third")[:queue]).to eq("main")
      expect(subject.composed(:bank_deposit)).to have_undone_step(:two).on_queue(:stripe)
      expect(subject.composed(:bank_deposit)).to have_undone_step(:one).on_queue(:stripe)
      expect(subject).to have_undone_step(:second).on_queue(:main)
      expect(subject).to have_undone_step(:first).on_queue(:main)
      expect(subject).to have_hopped_queues(:stripe, :main)
      expect(subject).to have_hopped_queues(:stripe, :main).during_rollback
    end

    it "lets a composed child's entries hop for themselves, never looping on the compose (H-9)" do
      subject = started(QueueFixtures::MainNestedFailing)
      perform_all

      expect(subject).to be_failure
      expect(subject).to have_hopped_queues(:stripe, :ledger, :stripe, :main).during_rollback
      expect(QueueFixtures.run_log.grep(/\Aundo:/)).to eq(%w[undo:s.three undo:ledger undo:s.one undo:m.second
                                                             undo:m.first])
      expect(subject.composed(:bank_deposit)).to have_undone_step(:two).on_queue(:ledger)
    end

    it "rolls back in the calling process, with no hop, a run that never left it" do
      stub_const("CallerFailing", Class.new(RollbackRecorder::Reactor) do
        tag "c"
        queue :main
        recording_step :first
        recording_step :second, after: :first, fail: true
        recording_step :third, after: :second
        background after: :third
      end)
      subject = started(CallerFailing)

      expect(subject).to be_failure
      expect(pending_async_jobs).to be_empty
      expect(QueueFixtures.run_log).to eq(%w[run:c.first run:c.second compensate:c.second undo:c.first])
      expect(subject).to have_hopped_queues.during_rollback
      expect(subject).to have_undone_step(:first)
      expect(subject).not_to have_undone_step(:first).on_queue(:main)
    end
  end
end
