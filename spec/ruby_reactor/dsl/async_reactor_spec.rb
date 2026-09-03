# frozen_string_literal: true

require "spec_helper"

# US3: a whole nested reactor dispatched to run independently — linked to the
# parent for traceability, deliberately outside its compensation graph.
RSpec.describe "`async_reactor`" do
  before { AsyncReactorFixtures.reset! }

  def drain
    RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs
  end

  describe "fire-and-forget isolation" do
    for_each_async_backend do
      it "never compensates the parent for a child failure nothing reads" do
        result = AsyncReactorFireAndForgetReactor.run(user_id: 7)
        drain

        expect(AsyncReactorFixtures.log).to include([:child_failed, nil])
        expect(AsyncReactorFixtures.compensated).to be_empty
        expect(AsyncReactorFireAndForgetReactor.find(result.execution_id).context.status.to_s)
          .to eq("completed")
      end

      it "does not register the child in the parent's compensation graph" do
        config = AsyncReactorFireAndForgetReactor.steps[:create_profile]

        expect(config.compensate_block).to be_nil
        expect(config.undo_block).to be_nil
      end
    end
  end

  describe "the link recorded on the parent's context" do
    for_each_async_backend do
      it "carries the child's execution id and class" do
        result = AsyncReactorFireAndForgetReactor.run(user_id: 7)
        ref = AsyncReactorFireAndForgetReactor.find(result.execution_id)
                                              .context.composed_contexts[:create_profile]

        expect(ref[:type]).to eq(:async_reactor_ref)
        expect(ref[:execution_id]).not_to be_nil
        expect(ref[:reactor_class_name]).to eq("AsyncChildFailsReactor")
      end

      it "points at a child execution that is addressable on its own" do
        result = AsyncReactorFireAndForgetReactor.run(user_id: 7)
        ref = AsyncReactorFireAndForgetReactor.find(result.execution_id)
                                              .context.composed_contexts[:create_profile]
        drain

        child = AsyncChildFailsReactor.find(ref[:execution_id])
        expect(child.context.status.to_s).to eq("failed")
      end
    end
  end

  # The reader blocks inside `.run`, so only a real worker can complete the
  # child while the caller waits.
  describe "awaited outcome" do
    for_each_real_async_backend do
      it "hands the reader the child's real Success, not the enqueue-time DispatchResult" do
        result = AsyncReactorAwaitedReactor.run(user_id: 7)

        expect(AsyncReactorFixtures.log).to include([:verify_all, "RubyReactor::Success"])
        expect(result).to be_success
        expect(result.value).to eq({ account_id: "acct-7" })
      end

      it "hands the reader the child's real Failure to inspect" do
        AsyncReactorAwaitedFailingReactor.run(user_id: 7)

        expect(AsyncReactorFixtures.log).to include([:verify, "RubyReactor::Failure"])
      end

      it "compensates the parent when the reader turns that failure into its own" do
        AsyncReactorAwaitedFailingReactor.run(user_id: 7)

        expect(AsyncReactorFixtures.compensated).to include(:setup)
      end
    end
  end

  describe "a child paused at an interrupt" do
    around do |example|
      original = RubyReactor.configuration.async_wait_timeout
      RubyReactor.configuration.async_wait_timeout = 2
      example.run
    ensure
      RubyReactor.configuration.async_wait_timeout = original
    end

    for_each_async_backend do
      it "is not terminal, so the reader waits and then times out" do
        result = AsyncReactorPausingChildParentReactor.run(user_id: 7)

        expect(result).to be_a(RubyReactor::Failure)
        expect(result.message).to match(/Timed out after 2s waiting for async completion/)
      end

      it "resolves once the child is resumed" do
        parent = AsyncReactorPausingChildParentReactor.run(user_id: 7)
        drain

        # The ref is written synchronously at dispatch, so it survives the
        # parent's own timeout failure.
        child_id = AsyncReactorPausingChildParentReactor.find(parent.execution_id)
                                                        .context.composed_contexts[:child][:execution_id]
        expect(AsyncPausingChildReactor.find(child_id).context.status.to_s).to eq("paused")

        AsyncPausingChildReactor.continue(id: child_id, step_name: :await_approval, payload: { ok: true })
        expect(AsyncPausingChildReactor.find(child_id).context.status.to_s).to eq("completed")
      end
    end
  end

  # Async units are independent units of work with independent compensation
  # flows: the parent rolling back must not "undo" a dispatch whose unit runs
  # (and may still succeed) elsewhere.
  describe "compensation independence" do
    for_each_real_async_backend do
      it "compensates the parent's own steps but never the dispatch itself" do
        result = AsyncReactorAwaitedFailingReactor.run(user_id: 7)

        trace = AsyncReactorAwaitedFailingReactor.find(result.execution_id).context.execution_trace
        undone = trace.select { |e| (e[:type] || e["type"]).to_s == "undo" }
                      .map { |e| (e[:step] || e["step"]).to_s }
        expect(undone).to include("setup")
        expect(undone).not_to include("create_profile")
      end
    end
  end

  # A reader inside a WORKER must not pin its thread for the child's whole
  # runtime: after PARK_GRACE it parks (job re-enqueued via the snooze path)
  # with the exclusive lock kept held across the gap.
  describe "parked wait inside a worker" do
    def eventually(timeout:, interval: 0.2)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        value = yield
        return value if value

        raise "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep interval
      end
    end

    for_each_real_async_backend do
      it "parks instead of blocking, keeps the lock held across the gap, and completes" do
        dispatch = AsyncParkingParentReactor.run(user_id: "prk1")
        expect(dispatch).to be_a(RubyReactor::DispatchResult)
        redis = Redis.new(url: REDIS_TEST_URL)

        eventually(timeout: 30) do
          data = AsyncParkingParentReactor.find(dispatch.execution_id)&.context&.private_data || {}
          data[:parked_primitives] || data["parked_primitives"]
        end
        # Parked: no live job is executing this context, yet the exclusive
        # lock is still checked out — that is the whole point.
        expect(redis.exists?("lock:parking:prk1")).to be(true)

        eventually(timeout: 45) do
          AsyncParkingParentReactor.find(dispatch.execution_id).context.status.to_s == "completed"
        end
        expect(redis.exists?("lock:parking:prk1")).to be(false)
      ensure
        redis&.close
      end
    end
  end

  describe "definition-time guards" do
    it "rejects `returns` naming an async_reactor" do
      expect do
        Class.new(RubyReactor::Reactor) do
          async_reactor :child, AsyncChildSucceedsReactor
          returns :child
        end
      end.to raise_error(RubyReactor::Error::ValidationError, /is an `async_reactor`/)
    end
  end

  it "builds a step whose type the dashboard can identify" do
    config = AsyncReactorAwaitedReactor.steps[:create_account]

    expect(config.async_dispatch).to eq(:reactor)
    expect(RubyReactor::Web::API.determine_step_type(config)).to eq("async_reactor")
  end
end
