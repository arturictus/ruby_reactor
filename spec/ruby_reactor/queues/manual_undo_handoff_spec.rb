# frozen_string_literal: true

require "spec_helper"

# 011 US2-AS11, FR-018, P-4: a manual undo of a run whose tree declares a queue
# hands the rollback to a worker, which undoes each unit on its own queue; a
# run without declarations is undone in the caller, as before.
RSpec.describe "manual undo across queues (US2)", type: :reactor do
  def perform_all(limit: 50)
    count = 0
    while (job = QueueProbe.next_job)
      job.perform!
      count += 1
      raise "more than #{limit} jobs" if count > limit
    end
    count
  end

  def undo_queue(context, step)
    context.execution_trace.find { |entry| entry[:type].to_s == "undo" && entry[:step].to_s == step }&.dig(:queue)
  end

  def status(reactor_class, id)
    reactor_class.find(id).context.status.to_s
  end

  before do
    stub_const("UndoValidated", Class.new(RollbackRecorder::Reactor) do
      tag "v"
      queue :main
      recording_step :first
      interrupt(:approve) do
        wait_for :first
        validate_payload { required(:ok).filled(:bool) }
        max_attempts 1
      end
      recording_step :after, after: :approve
    end)
    stub_const("UndoCrashStep", Class.new(RubyReactor::Step) do
      def run = Failure("x failed")

      def compensate
        RollbackRecorder.record("compensate:x")
        raise Interrupt, "deploy" if (RollbackRecorder.counters["x"] += 1) == 1

        Success()
      end
    end)
    stub_const("UndoAborted", Class.new(RollbackRecorder::Reactor) do
      tag "ab"
      queue :main
      recording_step :a
      step(:x, UndoCrashStep) { wait_for :a }
    end)
    stub_const("UndoUndeclared", Class.new(RollbackRecorder::Reactor) do
      tag "p"
      recording_step :first
      interrupt(:approve) { wait_for :first }
      recording_step :after, after: :approve
    end)
  end

  for_each_async_backend do
    it "hands the undo to a worker, undoing each unit on its own queue (AS11)" do
      result = QueueFixtures::MainApproval.run({})
      perform_all
      id = result.execution_id
      expect(status(QueueFixtures::MainApproval, id)).to eq("paused")

      expect(QueueFixtures::MainApproval.undo(id)).to be_nil
      expect(status(QueueFixtures::MainApproval, id)).to eq("rolling_back")
      expect(QueueFixtures.queues_of_pending).to eq(["stripe"])

      expect { QueueFixtures::MainApproval.undo(id) }.to raise_error(RubyReactor::Error::ValidationError)
      expect { QueueFixtures::MainApproval.cancel(id: id, reason: "no") }
        .to raise_error(RubyReactor::Error::ValidationError)
      expect do
        QueueFixtures::MainApproval.continue(id: id, payload: { ok: true }, step_name: %i[deposit approve])
      end.to raise_error(RubyReactor::Error::ValidationError)

      perform_all
      expect(status(QueueFixtures::MainApproval, id)).to eq("cancelled")
      expect(QueueFixtures.run_log.grep(/\Aundo:/)).to eq(%w[undo:s.one undo:m.first])

      context = QueueFixtures::MainApproval.find(id).context
      child = (context.composed_contexts[:deposit] || context.composed_contexts["deposit"])[:context]
      expect(undo_queue(context, "first")).to eq("main")
      expect(undo_queue(child, "one")).to eq("stripe")
    end

    it "ends `failed` with the reason when an interrupt's payload attempts run out" do
      result = UndoValidated.run({})
      id = result.execution_id

      failure = UndoValidated.continue(id: id, payload: { ok: "nope" }, step_name: :approve)
      expect(failure).to be_failure
      expect(status(UndoValidated, id)).to eq("rolling_back")
      expect(QueueFixtures.queues_of_pending).to eq(["main"])

      perform_all
      context = UndoValidated.find(id).context
      expect(context.status.to_s).to eq("failed")
      expect(context.failure_reason.to_s).to include("Validation failed after 1 attempts")
      expect(QueueFixtures.run_log).to include("undo:v.first")
    end

    it "runs an aborted run's cut-off compensate first, in the worker (010 R-10)" do
      expect { UndoAborted.run({}) }.to raise_error(Interrupt)
      id = RubyReactor.configuration.storage_adapter.scan_reactors(count: 10).first[:id]
      expect(status(UndoAborted, id)).to eq("aborted")

      UndoAborted.undo(id)
      perform_all

      expect(status(UndoAborted, id)).to eq("cancelled")
      expect(QueueFixtures.run_log).to eq(%w[run:ab.a compensate:x compensate:x undo:ab.a])
    end

    it "undoes a run without queue declarations in the caller, as before (FR-024)" do
      result = UndoUndeclared.run({})
      id = result.execution_id

      UndoUndeclared.undo(id)

      expect(status(UndoUndeclared, id)).to eq("cancelled")
      expect(pending_async_jobs).to be_empty
      expect(QueueFixtures.run_log).to eq(%w[run:p.first undo:p.first])
    end
  end
end
