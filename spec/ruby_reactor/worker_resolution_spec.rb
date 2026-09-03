# frozen_string_literal: true

require "spec_helper"

# A job whose reactor class cannot be resolved must fail the CONTEXT, durably,
# on the first delivery — not raise, burn the retry budget on an error retries
# can never fix, and leave the context "running" forever while every reader
# waits out its timeout (the AsyncReactorDemoReactor incident).
RSpec.describe RubyReactor::Worker do
  let(:harness_class) do
    Class.new do
      include RubyReactor::Worker

      def self.perform_in(*); end
    end
  end

  let(:storage) { RubyReactor.configuration.storage_adapter }

  def store_running_context(reactor_class_name)
    context = RubyReactor::Context.new({}, nil)
    context.status = :running
    storage.store_context(
      context.context_id, RubyReactor::ContextSerializer.serialize(context), reactor_class_name
    )
    context.context_id
  end

  describe "an unresolvable reactor class name" do
    it "marks the context failed instead of raising" do
      context_id = store_running_context("TotallyMissingReactorClass")

      expect { harness_class.new.perform(context_id, "TotallyMissingReactorClass") }.not_to raise_error

      stored = storage.retrieve_context(context_id, "TotallyMissingReactorClass")
      expect(stored["status"]).to eq("failed")
      expect(stored.dig("failure_reason", "message")).to match(/could not be resolved/)
    end
  end

  describe ".record_retries_exhausted" do
    it "fails a still-running context so readers stop waiting for a discarded job" do
      context_id = store_running_context("ExhaustedSpecReactor")

      described_class.record_retries_exhausted([context_id, "ExhaustedSpecReactor"], RuntimeError.new("boom"))

      stored = storage.retrieve_context(context_id, "ExhaustedSpecReactor")
      expect(stored["status"]).to eq("failed")
      expect(stored.dig("failure_reason", "message")).to match(/retries exhausted.*boom/)
    end

    it "leaves an already-terminal context untouched" do
      context = RubyReactor::Context.new({}, nil)
      context.status = :completed
      storage.store_context(
        context.context_id, RubyReactor::ContextSerializer.serialize(context), "ExhaustedSpecReactor"
      )

      described_class.record_retries_exhausted([context.context_id, "ExhaustedSpecReactor"],
                                               RuntimeError.new("boom"))

      stored = storage.retrieve_context(context.context_id, "ExhaustedSpecReactor")
      expect(stored["status"]).to eq("completed")
    end

    it "never raises, even with garbage args" do
      expect { described_class.record_retries_exhausted([nil], RuntimeError.new("boom")) }.not_to raise_error
    end
  end
end
