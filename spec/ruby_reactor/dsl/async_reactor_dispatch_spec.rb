# frozen_string_literal: true

require "spec_helper"

# FR-016: dispatch reuses the FULL pre-enqueue sequence of a top-level async run
# — validate the child's inputs, assign its ordering nonce, persist, then
# enqueue — never a raw `perform_async`. The worker's resume path never
# validates, so skipping validation here would start a child on garbage inputs.
RSpec.describe "`async_reactor` dispatch safeguards" do
  before { AsyncReactorFixtures.reset! }

  for_each_async_backend do
    it "fails the DISPATCHING step when the child's mapped inputs are invalid" do
      result = AsyncReactorInvalidChildInputsReactor.run

      expect(result).to be_a(RubyReactor::Failure)
      expect(result.message).to include("rejected its inputs")
    end

    it "does not enqueue a child it could not validate" do
      AsyncReactorInvalidChildInputsReactor.run

      expect(RubyReactor::RSpec::AsyncTestHelpers.pending_async_jobs).to be_empty
    end

    it "assigns the child's ordered-lock nonce at ENQUEUE time" do
      result = AsyncReactorOrderedChildReactor.run(queue: "q1")
      ref = AsyncReactorOrderedChildReactor.find(result.execution_id)
                                           .context.composed_contexts[:child]

      child_data = RubyReactor.configuration.storage_adapter
                              .retrieve_context(ref[:execution_id], "AsyncOrderedLockChildReactor")
      ordered = RubyReactor::ContextSerializer.deserialize_value(child_data["private_data"])[:ordered_lock]

      expect(ordered[:key]).to eq("ordered:q1")
      expect(ordered[:nonce]).not_to be_nil
    end

    it "persists the child context BEFORE the job exists, so the worker can find it" do
      result = AsyncReactorFireAndForgetReactor.run(user_id: 7)
      ref = AsyncReactorFireAndForgetReactor.find(result.execution_id)
                                            .context.composed_contexts[:create_profile]

      # The job is still queued at this point — the context must already be there.
      expect(RubyReactor::RSpec::AsyncTestHelpers.pending_async_jobs).not_to be_empty
      expect(RubyReactor.configuration.storage_adapter
                        .retrieve_context(ref[:execution_id], "AsyncChildFailsReactor")).not_to be_nil
    end

    it "links the child to the parent by execution id for traceability" do
      result = AsyncReactorFireAndForgetReactor.run(user_id: 7)
      ref = AsyncReactorFireAndForgetReactor.find(result.execution_id)
                                            .context.composed_contexts[:create_profile]

      child_data = RubyReactor.configuration.storage_adapter
                              .retrieve_context(ref[:execution_id], "AsyncChildFailsReactor")
      expect(child_data["parent_context_id"]).to eq(result.execution_id)
    end
  end
end
