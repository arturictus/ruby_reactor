# frozen_string_literal: true

require "spec_helper"

# US2: one step's work leaves this process while the reactor keeps going.
RSpec.describe "`async_step`" do
  before do
    AsyncStepFixtures.reset!
    AsyncStepFailingNoReaderReactor.reset!
    AsyncStepFailingWithReaderReactor.reset!
  end

  def drain
    RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs
  end

  describe "dispatch" do
    for_each_async_backend do
      it "does not block a sibling that has no dependency on it" do
        AsyncStepSiblingReactor.run(email: "a@b.c")

        # The sibling ran here; the async step has not run at all yet.
        expect(AsyncStepFixtures.log).to eq([[:do_something_same_thread, nil]])
      end

      it "queues the work as its own job rather than the whole reactor" do
        AsyncStepSiblingReactor.run(email: "a@b.c")

        expect(RubyReactor::RSpec::AsyncTestHelpers.pending_async_jobs.size).to eq(1)
      end

      it "runs the dispatched work when the job is drained" do
        AsyncStepSiblingReactor.run(email: "a@b.c")
        drain

        expect(AsyncStepFixtures.log).to include([:send_email, "a@b.c"])
      end

      it "records the reference on the parent's own context" do
        result = AsyncStepSiblingReactor.run(email: "a@b.c")
        context = AsyncStepSiblingReactor.find(result.execution_id).context
        ref = context.composed_contexts[:send_email]

        expect(ref[:type]).to eq(:async_step_ref)
        expect(ref[:context_id]).to eq(context.context_id)
      end

      it "writes the durable record BEFORE the job can run, as the re-attach marker" do
        result = AsyncStepSiblingReactor.run(email: "a@b.c")

        record = RubyReactor.configuration.storage_adapter.retrieve_step_result(
          result.execution_id, :send_email, "AsyncStepSiblingReactor"
        )
        expect(record["status"]).to eq("dispatched")
      end

      it "re-attaches instead of dispatching a duplicate when a record already exists" do
        result = AsyncStepSiblingReactor.run(email: "a@b.c")
        drain

        # Re-running the same execution must not enqueue the unit a second time
        # — the side effect is already out there.
        AsyncStepSiblingReactor.find(result.execution_id)
        expect(RubyReactor::RSpec::AsyncTestHelpers.pending_async_jobs).to be_empty
        expect(AsyncStepFixtures.log.count { |e| e.first == :send_email }).to eq(1)
      end

      it "still dispatches its own job when reached inside a worker" do
        AsyncStepAfterBackgroundReactor.run
        drain

        expect(AsyncStepFixtures.log).to include([:dispatched_in_worker, nil])
      end
    end
  end

  # These need a REAL worker: the reader blocks inside `.run`, so it is the very
  # thing that would have to drain a fake queue. See spec/support/real_async_backend.rb.
  describe "read semantics" do
    for_each_real_async_backend do
      it "gives the reader the raw deserialized value on Success" do
        result = AsyncStepReaderReactor.run(email: "a@b.c")

        expect(AsyncStepFixtures.log).to include([:check_email, { delivered_to: "a@b.c" }])
        expect(AsyncStepReaderReactor.find(result.execution_id).context.status.to_s).to eq("completed")
      end

      it "gives the reader the Failure object itself so it can inspect and decide" do
        AsyncStepFailingWithReaderReactor.run

        expect(AsyncStepFixtures.log).to include([:inspect_risky, "RubyReactor::Failure"])
      end
    end
  end

  describe "compensation is opt-in" do
    for_each_async_backend do
      it "leaves the parent uncompensated when a failing async step has no reader" do
        result = AsyncStepFailingNoReaderReactor.run
        drain

        record = RubyReactor.configuration.storage_adapter.retrieve_step_result(
          result.execution_id, :risky, "AsyncStepFailingNoReaderReactor"
        )
        expect(record["success"]).to be false
        expect(AsyncStepFailingNoReaderReactor.compensated).to be_empty
      end
    end

    for_each_real_async_backend do
      it "compensates when a reader inspects the failure and returns Failure" do
        AsyncStepFailingWithReaderReactor.run

        expect(AsyncStepFailingWithReaderReactor.compensated).to include(:setup)
      end
    end
  end

  describe "definition-time guards" do
    it "rejects `returns` naming an async_step" do
      expect do
        Class.new(RubyReactor::Reactor) do
          async_step(:dispatched) { run { RubyReactor.Success(:x) } }
          returns :dispatched
        end
      end.to raise_error(RubyReactor::Error::ValidationError, /is an `async_step`/)
    end

    it "still allows `returns` on an ordinary step alongside one" do
      reactor = Class.new(RubyReactor::Reactor) do
        async_step(:dispatched) { run { RubyReactor.Success(:x) } }
        step(:here) { run { RubyReactor.Success(:y) } }
        returns :here
      end

      expect(reactor.return_step).to eq(:here)
    end
  end

  it "builds a normal StepConfig, so every step option keeps working" do
    reactor = Class.new(RubyReactor::Reactor) do
      async_step :dispatched do
        argument :x, value(1)
        retries max_attempts: 2
        run { RubyReactor.Success(:x) }
        compensate { RubyReactor.Success() }
      end
    end

    config = reactor.steps[:dispatched]
    expect(config).to be_a(RubyReactor::Dsl::StepConfig)
    expect(config.async_dispatch).to eq(:step)
    expect(config.retry_config[:max_attempts]).to eq(2)
    expect(config.compensate_block).not_to be_nil
  end
end
