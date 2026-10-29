# frozen_string_literal: true

require "rails_helper"

RSpec.describe QueueDemoReactor, type: :reactor do
  it "runs each unit on its own queue, hopping to the deposit's queue and back" do
    reactor = test_reactor(described_class, { amount: 42 })

    expect(reactor).to be_success
    expect(reactor).to have_run_step(:price).on_queue(:demo_orders)
    expect(reactor).to have_run_step(:confirm).on_queue(:demo_orders)
    expect(reactor.composed(:deposit)).to have_run_step(:charge).on_queue(:demo_stripe)
    expect(reactor.composed(:deposit)).to have_run_step(:settle).on_queue(:demo_stripe)
    expect(reactor).to have_run_step(:email).on_queue(:demo_emails)
    expect(reactor).to have_hopped_queues(:demo_stripe, :demo_orders)
  end

  it "hands off from the caller to the queue of the first step the worker runs" do
    reactor = test_reactor(described_class, { amount: 42 }, process_jobs: false)
    reactor.run

    expect(pending_async_jobs.map(&:queue)).to eq(["demo_orders"])
  end

  it "undoes each unit on its own queue when confirming fails" do
    reactor = test_reactor(described_class, { amount: 42, fail_at_confirm: true })

    expect(reactor).to be_failure
    expect(reactor.composed(:deposit)).to have_undone_step(:charge).on_queue(:demo_stripe)
    expect(reactor.composed(:deposit)).to have_undone_step(:settle).on_queue(:demo_stripe)
    expect(reactor).to have_undone_step(:price).on_queue(:demo_orders)
    expect(reactor).to have_undone_step(:reserve).on_queue(:demo_orders)
    expect(reactor).to have_hopped_queues(:demo_stripe, :demo_orders).during_rollback
  end

  it "hands a manual undo to a worker, which undoes each unit on its own queue" do
    reactor = test_reactor(described_class, { amount: 42 }, process_jobs: false)
    reactor.run
    drain_async_jobs
    expect(reactor).to be_success

    reactor.undo(process_jobs: false)
    expect(reactor).to be_rolling_back
    expect(pending_async_jobs.map(&:queue)).to eq(["demo_orders"])

    drain_async_jobs
    expect(reactor).to have_undone_step(:confirm).on_queue(:demo_orders)
    expect(reactor.composed(:deposit)).to have_undone_step(:charge).on_queue(:demo_stripe)
  end
end
