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
        expect(json["error"]["message"]).to eq("Step 'step2' failed after 1 attempts: Something went wrong")
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
end
