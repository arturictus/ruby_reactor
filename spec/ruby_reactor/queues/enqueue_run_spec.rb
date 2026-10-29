# frozen_string_literal: true

require "spec_helper"

# 011 R-04: every dispatch of a run's Worker records where it went, before the
# job exists (H-1), and picks the queue: the given one, else the run's record,
# else the reactor's own.
RSpec.describe "Queues.enqueue_run" do
  let(:storage) { RubyReactor.configuration.storage_adapter }
  let(:id) { SecureRandom.uuid }
  let(:router) { class_double(RubyReactor::Adapters::Sidekiq::Router) }

  before do
    stub_const("EnqueueRunDeclared", Class.new(RubyReactor::Reactor) { queue :stripe })
    stub_const("EnqueueRunPlain", Class.new(RubyReactor::Reactor))
    allow(router).to receive(:perform_async) { RubyReactor::DispatchResult.new(job_id: "j") }
    allow(router).to receive(:perform_in) { RubyReactor::DispatchResult.new(job_id: "j") }
  end

  def enqueue(name, **options)
    RubyReactor::Queues.enqueue_run(id, name, router: router, **options)
  end

  it "records the queue before the job is enqueued" do
    allow(router).to receive(:perform_async) do |*_args, **kwargs|
      expect(storage.retrieve_run_dispatch(id, "EnqueueRunPlain")["queue"]).to eq(kwargs[:queue])
      RubyReactor::DispatchResult.new(job_id: "j")
    end

    expect(enqueue("EnqueueRunPlain", queue: "ledger")).to be_a(RubyReactor::DispatchResult)
    expect(router).to have_received(:perform_async).with(id, "EnqueueRunPlain", queue: "ledger")
  end

  it "falls back to the run's record, then to the reactor's queue" do
    enqueue("EnqueueRunDeclared")
    expect(router).to have_received(:perform_async).with(id, "EnqueueRunDeclared", queue: "stripe")

    storage.store_run_dispatch(id, "EnqueueRunDeclared", "ledger")
    enqueue("EnqueueRunDeclared")
    expect(router).to have_received(:perform_async).with(id, "EnqueueRunDeclared", queue: "ledger")
  end

  it "passes no queue for a run on the global queue" do
    enqueue("EnqueueRunPlain")
    expect(router).to have_received(:perform_async).with(id, "EnqueueRunPlain")
    expect(storage.retrieve_run_dispatch(id, "EnqueueRunPlain")["queue"]).to eq("default")
  end

  it "delays through perform_in, carrying the snooze count only with a queue" do
    enqueue("EnqueueRunDeclared", delay: 5, snooze_count: 2)
    expect(router).to have_received(:perform_in).with(5, id, "EnqueueRunDeclared", queue: "stripe", snooze_count: 2)

    enqueue("EnqueueRunPlain", delay: 5, snooze_count: 2)
    expect(router).to have_received(:perform_in).with(5, id, "EnqueueRunPlain")
  end

  it "uses the configured router when none is given" do
    allow(RubyReactor.configuration).to receive(:async_router).and_return(router)
    RubyReactor::Queues.enqueue_run(id, "EnqueueRunPlain")
    expect(router).to have_received(:perform_async)
  end
end
