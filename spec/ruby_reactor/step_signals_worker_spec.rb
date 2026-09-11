# frozen_string_literal: true

require "spec_helper"

# Regression guard for research.md D4 (US2 scenario 2): before the base class
# owned the `catch(StepSignals::TAG)`, StepWorker#execute_step_body had no
# catch of its own, so a `fail!`/`success!`/`skip!`/`halt!` inside a class
# step's `run` running under `async_step`/`background` escaped as an
# UncaughtThrowError instead of the intended signal — a Failure wrapping the
# wrong error, and (before T024) reported retryable when it should not be.
# With RubyReactor::Step's class-level `run` catching the signal itself, this
# passes with no StepWorker change at all.
RSpec.describe "Class step signals on the async worker path" do
  def drain
    RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs
  end

  before do
    stub_const("WorkerFailStep", Class.new(RubyReactor::Step) do
      def run = fail!("nope")
    end)
  end

  for_each_async_backend do
    it "translates fail! into the intended Failure, never an UncaughtThrowError" do
      reactor = stub_const("WorkerSignalReactor", Class.new(RubyReactor::Reactor) do
        async_step :boom, WorkerFailStep
      end)

      dispatch = reactor.run
      drain

      record = RubyReactor.configuration.storage_adapter.retrieve_step_result(
        dispatch.execution_id, :boom, "WorkerSignalReactor"
      )

      expect(record["success"]).to be(false)
      expect(record["result"]["error"]).to eq("nope")
    end
  end
end
