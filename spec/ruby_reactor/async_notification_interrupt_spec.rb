# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Async Notification Interrupt Reactor" do
  let(:reactor_class) { AsyncNotificationInterruptReactor }

  before do
    reactor_class.instance_variable_set(:@trace, [])
    # Clear Redis
    RubyReactor::Configuration.instance.storage_adapter.respond_to?(:flushdb) &&
      RubyReactor::Configuration.instance.storage_adapter.flushdb

    # Ensure sidekiq testing is in inline mode to simulate async job running immediately
    # OR we can control it manually
    Sidekiq::Testing.inline!
  end

  after do
    Sidekiq::Testing.fake!
  end

  it "executes async step then pauses for interrupt and resumes" do
    # 1. Run reactor
    # retrieve_context (sync) -> send_notifications (async) -> manager_approval (interrupt)
    # Sidekiq::Testing.inline! means the async job runs synchronously.
    # However, AsyncRouter still returns AsyncResult packaging the job_id.

    execution = reactor_class.run

    # In default test env (WorkerMock), run returns the result directly because it executes inline
    expect(execution).to be_a(RubyReactor::InterruptResult)
    execution_id = execution.execution_id

    # Verify trace (inline execution happened)
    expect(reactor_class.trace).to eq(%i[retrieve_context send_notifications])

    # 2. Check stored state
    stored_context = RubyReactor::Configuration.instance.storage_adapter.retrieve_context(execution_id,
                                                                                          reactor_class.name)
    expect(stored_context).not_to be_nil

    # 3. Resume with approval
    # This resumes 'manager_approval'.
    # Then 'process_approval' runs. It is ALSO async.
    # So continue will return AsyncResult.
    result = reactor_class.continue(
      id: execution_id,
      step_name: :manager_approval,
      payload: { status: "approved" }
    )

    # In default test env (WorkerMock), continue runs the async step inline and returns the result (Success)
    expect(result).to be_a(RubyReactor::Success)

    # Inline execution should have completed 'process_approval'
    expect(reactor_class.trace).to eq(%i[retrieve_context send_notifications process_approval])

    expect(result.value).to eq("processed_approved_after_notifications_sent_to_123")

    # Verify final result by reloading context or checking return value if we could (but AsyncResult hides it)
    reactor = reactor_class.find(execution_id)
    # The context should have the results set
    expect(reactor.context.result(:manager_approval)).to eq({ status: "approved" })

    # process_approval result would be in intermediate_results
    process_result = reactor.context.result(:process_approval)
    # NOTE: process_approval result depends on argument interpolation which we fixed
    expect(process_result).to eq("processed_approved_after_notifications_sent_to_123")
  end

  context "with manual async execution" do
    before do
      # Use real SidekiqAdapter to test actual Sidekiq queuing
      allow(RubyReactor::Configuration.instance).to receive(:async_router).and_return(RubyReactor::SidekiqAdapter)
    end

    it "returns AsyncResult initially, then pauses at interrupt after worker runs" do
      # Force fake mode to ensure job is queued not executed
      Sidekiq::Testing.fake! do
        # 1. Run reactor -> retrieve_context (sync) -> send_notifications (async queued)
        result = reactor_class.run

        # Should return AsyncResult because send_notifications is async
        expect(result).to be_a(RubyReactor::AsyncResult)
        execution_id = result.execution_id

        expect(reactor_class.trace).to eq([:retrieve_context])

        # 2. Drain Sidekiq jobs to run send_notifications
        # This runs send_notifications and pauses at manager_approval
        RubyReactor::SidekiqWorkers::Worker.drain

        expect(reactor_class.trace).to eq(%i[retrieve_context send_notifications])

        # 3. Resume with approval
        # Resumes manager_approval -> queues process_approval (async)
        resume_result = reactor_class.continue(
          id: execution_id,
          step_name: :manager_approval,
          payload: { status: "approved" }
        )

        expect(resume_result).to be_a(RubyReactor::AsyncResult)

        # process_approval hasn't run yet (it's queued)
        expect(reactor_class.trace).to eq(%i[retrieve_context send_notifications])

        # 4. Drain again to run process_approval
        RubyReactor::SidekiqWorkers::Worker.drain

        expect(reactor_class.trace).to eq(%i[retrieve_context send_notifications process_approval])

        # Verify final result
        reactor = reactor_class.find(execution_id)
        process_result = reactor.context.result(:process_approval)
        expect(process_result).to eq("processed_approved_after_notifications_sent_to_123")
      end
    end
  end
end
