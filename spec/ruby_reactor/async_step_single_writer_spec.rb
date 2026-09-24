# frozen_string_literal: true

require "spec_helper"

# A context is written by one process only: the execution that owns it. An
# `async_step` unit runs in its own worker, so it writes ONLY its own Step
# Result Record — never the parent's context, which holds nothing but the link
# written at dispatch (`composed_contexts[step] = { type: :async_step_ref }`).
# The dashboard rebuilds the unit's run from that link.
RSpec.describe "an async_step unit writes only its own Step Result Record" do
  let(:storage) { RubyReactor.configuration.storage_adapter }
  let(:step_worker) { RubyReactor::Adapters::Sidekiq::StepWorker }

  before do
    AsyncStepFixtures.reset!
    AsyncStepRetryReactor.reset!
  end

  def perform_unit
    job = step_worker.jobs.last
    step_worker.jobs.clear
    step_worker.new.perform(*job["args"])
  end

  def record_for(reactor, id, step)
    storage.retrieve_step_result(id, step, reactor.name)
  end

  it "leaves the parent's stored context untouched when the unit completes" do
    id = AsyncStepSiblingReactor.run(email: "a@b.c").execution_id
    parent = storage.retrieve_context(id, "AsyncStepSiblingReactor")

    perform_unit

    expect(record_for(AsyncStepSiblingReactor, id, :send_email)["status"]).to eq("completed")
    expect(storage.retrieve_context(id, "AsyncStepSiblingReactor")).to eq(parent)
  end

  it "leaves the parent's stored context untouched when the unit fails" do
    id = AsyncStepFailingNoReaderReactor.run({}).execution_id
    parent = storage.retrieve_context(id, "AsyncStepFailingNoReaderReactor")

    perform_unit

    expect(record_for(AsyncStepFailingNoReaderReactor, id, :risky)["success"]).to be(false)
    expect(storage.retrieve_context(id, "AsyncStepFailingNoReaderReactor")).to eq(parent)
  end

  it "never reverts a newer parent checkpoint stored while the unit ran" do
    id = SingleWriterReactor.run(marker: "newer").execution_id

    perform_unit

    parent = SingleWriterReactor.find(id).context
    expect(parent.private_data[:parent_checkpoint]).to eq("newer")
  end

  it "keeps the unit's run — its arguments and attempts — on its own record" do
    id = AsyncStepSiblingReactor.run(email: "a@b.c").execution_id
    perform_unit

    record = record_for(AsyncStepSiblingReactor, id, :send_email)
    expect(RubyReactor::ContextSerializer.deserialize_value(record["arguments"])).to eq(to: "a@b.c")
    expect(record["attempts"]).to eq(1)
    expect(Time.iso8601(record["started_at"])).to be_within(60).of(Time.now)
  end

  it "counts every in-worker retry attempt on the record" do
    id = AsyncStepRetryReactor.run({}).execution_id
    perform_unit

    expect(record_for(AsyncStepRetryReactor, id, :flaky)["attempts"]).to eq(3)
  end
end
