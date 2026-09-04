# frozen_string_literal: true

require "spec_helper"
require "ruby_reactor/web/api"

RSpec.describe RubyReactor::Web::API, type: :request do
  let(:reactor_class) { ApiTestReactor }

  describe "GET /reactors/:id" do
    context "when reactor fails" do
      it "returns status 'failed' and error details" do
        # 1. Execute reactor to failure using public API
        reactor_class.run(should_fail: true)

        # When run returns a Failure, it wraps the Result object.
        # But for the API test we need the context ID regardless of success/failure.
        # The result object (if Sync) is the final output, not the context.
        # However, for testing purposes, we can get the context ID from the result if it exposes it,
        # OR we can assume `run` returns the result.

        # Wait, `RubyReactor::Reactor#run` returns the result of the execution.
        # But we need the context ID to query the API.
        # `RubyReactor::Reactor` instance has `@context`.
        # So we should probably instantiate and run to keep access to context.

        reactor = reactor_class.new
        reactor.run(should_fail: true)
        context_id = reactor.context.context_id

        # 2. Query API
        get "/reactors/#{context_id}"

        # 3. Verify Response
        json = JSON.parse(last_response.body)

        expect(last_response.status).to eq(200)
        expect(json["status"]).to eq("failed")
        expect(json["error"]).not_to be_nil
        expect(json["error"]["error"]).to eq("Step 'step2' failed after 1 attempts: Something went wrong")
        expect(json["error"]["step_name"]).to eq("step2")
      end
    end

    context "when reactor succeeds" do
      it "returns status 'completed' and no error" do
        reactor = reactor_class.new
        reactor.run(should_fail: false)
        context_id = reactor.context.context_id

        get "/reactors/#{context_id}"

        json = JSON.parse(last_response.body)

        expect(last_response.status).to eq(200)
        expect(json["status"]).to eq("completed")
        expect(json["error"]).to be_nil
        expect(json).to have_key("coordination")
      end
    end

    context "when reactor has composed steps" do
      it "returns composed_contexts in the response" do
        reactor = ApiComposeTestReactor.new
        reactor.run
        context_id = reactor.context.context_id

        get "/reactors/#{context_id}"

        json = JSON.parse(last_response.body)

        expect(last_response.status).to eq(200)
        expect(json["composed_contexts"]).not_to be_empty
        expect(json["composed_contexts"]).to have_key("sub_reactor")

        # Composed Context is now returned cleaned and flat
        sub_context = json["composed_contexts"]["sub_reactor"]["context"]
        expect(sub_context).not_to be_nil
        expect(sub_context["intermediate_results"]).to have_key("inner_step")
        expect(sub_context["intermediate_results"]["inner_step"]).to eq(11)
      end
    end

    context "when reactor never started executing" do
      it "returns status 'pending' instead of inferring completed" do
        context = RubyReactor::Context.new({ should_fail: false }, ApiTestReactor)
        serialized = RubyReactor::ContextSerializer.serialize(context)
        RubyReactor.configuration.storage_adapter.store_context(
          context.context_id,
          serialized,
          "ApiTestReactor"
        )

        get "/reactors/#{context.context_id}"

        json = JSON.parse(last_response.body)

        expect(last_response.status).to eq(200)
        expect(json["status"]).to eq("pending")
        expect(json["intermediate_results"]).to eq({})
        expect(json["steps"]).to eq([])
      end
    end
  end

  describe "GET /reactors" do
    it "lists reactors with correct status" do
      # Create failed reactor
      fail_reactor = reactor_class.new
      fail_reactor.run(should_fail: true)
      fail_id = fail_reactor.context.context_id

      # Create success reactor
      success_reactor = reactor_class.new
      success_reactor.run(should_fail: false)
      success_id = success_reactor.context.context_id

      get "/reactors"

      json = JSON.parse(last_response.body)

      failed_item = json.find { |r| r["id"] == fail_id }
      success_item = json.find { |r| r["id"] == success_id }

      expect(failed_item["status"]).to eq("failed")
      expect(success_item["status"]).to eq("completed")
    end
  end

  describe "POST /reactors/:id/retry" do
    it "starts a new execution with the same inputs when reactor failed" do
      reactor = reactor_class.new
      reactor.run(should_fail: true)
      context_id = reactor.context.context_id

      post "/reactors/#{context_id}/retry"

      json = JSON.parse(last_response.body)

      expect(last_response.status).to eq(200)
      expect(json["success"]).to be true
      expect(json["id"]).not_to eq(context_id)

      retried = reactor_class.find(json["id"])
      expect(retried.context.inputs).to eq({ should_fail: true })
      expect(retried.context.parent_context_id).to be_nil
      expect(retried.context.retried_from_id).to eq(context_id)
      expect(retried.context.retry_count).to eq(1)
    end

    it "returns 422 when reactor is not failed" do
      reactor = reactor_class.new
      reactor.run(should_fail: false)
      context_id = reactor.context.context_id

      post "/reactors/#{context_id}/retry"

      json = JSON.parse(last_response.body)

      expect(last_response.status).to eq(422)
      expect(json["error"]).to eq("Reactor can only be retried when failed")
    end

    it "retries FormInterruptReactor with the same inputs" do
      reactor = FormInterruptReactorReproduction.new
      reactor.run(user_name: "Alice", fail_at: :prepare_application)
      context_id = reactor.context.context_id

      post "/reactors/#{context_id}/retry"

      json = JSON.parse(last_response.body)

      expect(last_response.status).to eq(200)
      expect(json["id"]).not_to eq(context_id)

      retried = FormInterruptReactorReproduction.find(json["id"])
      expect(retried.context.inputs).to eq({ user_name: "Alice", fail_at: :prepare_application })
      expect(retried.context.parent_context_id).to be_nil
      expect(retried.context.retried_from_id).to eq(context_id)
    end

    it "includes retried executions in the reactor list" do
      reactor = reactor_class.new
      reactor.run(should_fail: true)
      context_id = reactor.context.context_id

      post "/reactors/#{context_id}/retry"
      retried_id = JSON.parse(last_response.body)["id"]

      get "/reactors"

      json = JSON.parse(last_response.body)
      retried_item = json.find { |item| item["id"] == retried_id }

      expect(retried_item).not_to be_nil
      expect(retried_item["class"]).to eq("ApiTestReactor")
    end
  end

  # The dashboard must stay current with the reactor state model. The
  # fire-and-forget model makes this load-bearing rather than cosmetic — a
  # dispatched unit's outcome may have no other surface in the parent at all.
  describe "the new async step types" do
    it "identifies an async_step" do
      expect(described_class.determine_step_type(AsyncStepSiblingReactor.steps[:send_email]))
        .to eq("async_step")
    end

    it "identifies an async_reactor" do
      expect(described_class.determine_step_type(AsyncReactorAwaitedReactor.steps[:create_account]))
        .to eq("async_reactor")
    end

    it "still identifies ordinary, compose and map steps" do
      expect(described_class.determine_step_type(AsyncStepSiblingReactor.steps[:do_something_same_thread]))
        .to eq("step")
    end

    it "exposes the hand-off point once per reactor, not per step" do
      structure = described_class.build_structure(BackgroundAfterReactor)

      expect(described_class.background_handoff_for(BackgroundAfterReactor))
        .to eq({ mode: :after, step: :second })
      expect(structure.values.map(&:keys).flatten.uniq).not_to include(:async)
    end

    it "recurses into an async_reactor child's own step graph" do
      structure = described_class.build_structure(AsyncReactorAwaitedReactor)

      expect(structure[:create_account][:nested_structure]).to have_key(:create)
    end
  end

  describe "hydrating the new composed_contexts refs" do
    it "resolves an async_step_ref to its Step Result Record" do
      result = AsyncStepSiblingReactor.run(email: "a@b.c")
      context = AsyncStepSiblingReactor.find(result.execution_id).context

      hydrated = described_class.hydrate_composed_contexts(
        context.composed_contexts, "AsyncStepSiblingReactor"
      )
      expect(hydrated[:send_email]["record"]["status"]).to eq("dispatched")
    end

    it "resolves an async_reactor_ref to the linked child execution" do
      result = AsyncReactorFireAndForgetReactor.run(user_id: 7)
      context = AsyncReactorFireAndForgetReactor.find(result.execution_id).context

      hydrated = described_class.hydrate_composed_contexts(
        context.composed_contexts, "AsyncReactorFireAndForgetReactor"
      )
      expect(hydrated[:create_profile]["context"]["context_id"])
        .to eq(context.composed_contexts[:create_profile][:execution_id])
    end

    it "passes an unknown ref type through untouched" do
      expect(described_class.hydrate_composed_contexts({ x: { type: :composed, name: :x } }, "Any"))
        .to eq({ x: { type: :composed, name: :x } })
    end
  end

  # A failed map records no result on the parent, so the failing step showed
  # nothing in the dashboard while its element results sat in storage.
  describe ".with_map_summaries" do
    let(:storage) { instance_double(RubyReactor::Storage::RedisAdapter) }
    let(:structure) { { prepare: { type: "map" }, show: { type: "step" } } }

    before do
      allow(RubyReactor.configuration).to receive(:storage_adapter).and_return(storage)
    end

    it "fills a map step's missing result from its stored elements" do
      allow(storage).to receive(:count_map_results).with("ctx-1:prepare", "Parent").and_return(2)

      results = described_class.with_map_summaries({}, structure, "ctx-1", "Parent")

      expect(results[:prepare]).to be_a(RubyReactor::Map::ResultEnumerator)
      expect(results[:prepare].map_id).to eq("ctx-1:prepare")
    end

    it "leaves a recorded result and maps with no stored elements alone" do
      allow(storage).to receive(:count_map_results).and_return(0)

      expect(described_class.with_map_summaries({ prepare: [1] }, structure, "ctx-1", "Parent"))
        .to eq({ prepare: [1] })
      expect(described_class.with_map_summaries({}, structure, "ctx-1", "Parent")).to eq({})
    end
  end
end
