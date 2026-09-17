# frozen_string_literal: true

require "spec_helper"

# Regressions for the PR #51 review: each one is a place where the
# non-retryable / structured-error guarantee, or a step signal, was silently
# lost on the way through a serialization boundary.
RSpec.describe "Failure and signal metadata survive their round trips" do
  before do
    stub_const("ViolatingStep", Class.new(RubyReactor::Step) do
      input :n, :integer

      def run = Success(inputs)
    end)
  end

  describe "RubyReactor::Failure rebuilt from a serialized hash" do
    it "keeps a string-keyed `retryable => false` instead of defaulting back to retryable" do
      original = RubyReactor.Failure("bad input", retryable: false, validation_errors: { n: ["must be an integer"] })
      round_tripped = JSON.parse(JSON.generate(original.to_h))

      rebuilt = RubyReactor::Failure.new(round_tripped)

      expect(rebuilt.retryable?).to be(false)
      expect(rebuilt.validation_errors).to eq("n" => ["must be an integer"])
    end
  end

  describe "a reactor-input validation failure reloaded with .find" do
    it "is still non-retryable after the context round trip" do
      reactor = stub_const("ReloadedValidationReactor", Class.new(RubyReactor::Reactor) do
        input :n, :integer
        step(:only, ViolatingStep) { argument :n, input(:n) }
      end)

      instance = reactor.new
      result = instance.run(n: "not an integer")
      expect(result).to be_failure
      expect(result.retryable?).to be(false)

      reloaded = reactor.find(instance.context.context_id).result

      expect(reloaded).to be_failure
      expect(reloaded.retryable?).to be(false)
    end
  end

  describe "a step-contract violation inside compose" do
    it "reaches the parent with the child's structured field errors intact" do
      child = stub_const("ViolatingChildReactor", Class.new(RubyReactor::Reactor) do
        input :n
        step(:only, ViolatingStep) { argument :n, input(:n) }
      end)
      parent = Class.new(RubyReactor::Reactor) do
        input :n
        compose(:child, child) { argument :n, input(:n) }
      end

      result = parent.run(n: "not an integer")

      expect(result).to be_failure
      expect(result.retryable?).to be(false)
      expect(result.validation_errors).not_to be_nil
    end
  end

  describe "a reactor reopened after its first run" do
    it "re-checks the definition, so a newly declared required step input cannot reach execution unwired" do
      reactor = stub_const("ReopenedReactor", Class.new(RubyReactor::Reactor) do
        input :n
        step(:ok, ViolatingStep) { argument :n, input(:n) }
      end)

      expect(reactor.run(n: 1)).to be_success

      stub_const("LateStep", Class.new(RubyReactor::Step) do
        input :missing, :integer

        def run = Success(inputs)
      end)
      reactor.step(:late, LateStep)

      expect { reactor.run(n: 1) }.to raise_error(RubyReactor::Error::ValidationError, /requires input :missing/)
    end
  end

  describe "a class step that halts under async_step" do
    before do
      stub_const("WorkerHaltStep", Class.new(RubyReactor::Step) do
        def run = halt!(reason: "nothing to do")
      end)
    end

    for_each_async_backend do
      it "records the halt so the reader can observe it, rather than an ordinary nil success" do
        reactor = stub_const("WorkerHaltReactor", Class.new(RubyReactor::Reactor) do
          async_step :maybe, WorkerHaltStep
        end)

        dispatch = reactor.run
        RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs

        record = RubyReactor.configuration.storage_adapter.retrieve_step_result(
          dispatch.execution_id, :maybe, "WorkerHaltReactor"
        )

        expect(record["success"]).to be(true)
        expect(record["signal"]).to eq("halt")
        expect(record["reason"]).to eq("nothing to do")
      end
    end
  end
end
