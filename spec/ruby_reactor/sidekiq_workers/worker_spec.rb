# frozen_string_literal: true

require "spec_helper"
require "sidekiq/testing"
require "ruby_reactor/sidekiq_workers/worker"

RSpec.describe RubyReactor::SidekiqWorkers::Worker do
  subject(:worker) { described_class.new }

  let(:reactor_class) { Class.new { def self.name = "TestReactor" } }
  let(:context) do
    instance_double(
      RubyReactor::Context,
      context_id: "test-execution-id",
      reactor_class: reactor_class,
      inline_async_execution: true
    )
  end
  let(:executor) { instance_double(RubyReactor::Executor) }
  let(:serialized_context) { "{}" }

  before do
    allow(RubyReactor::ContextSerializer).to receive(:deserialize).and_return(context)
    allow(RubyReactor::Executor).to receive(:new).and_return(executor)
    allow(executor).to receive(:save_context)
    allow(executor).to receive(:skip_context_persist?).and_return(false)
    allow(context).to receive(:inline_async_execution=)
    # Deterministic delay for assertions
    RubyReactor.configuration.lock_snooze_base_delay = 5
    RubyReactor.configuration.lock_snooze_jitter = 0
    RubyReactor.configuration.lock_snooze_max_attempts = 20
  end

  describe "#perform" do
    it "executes the reactor" do
      allow(executor).to receive(:resume_execution)
      worker.perform(serialized_context)
      expect(executor).to have_received(:resume_execution)
    end

    context "when lock acquisition fails" do
      before do
        allow(executor).to receive(:resume_execution).and_raise(RubyReactor::Lock::AcquisitionError)
        allow(described_class).to receive(:perform_in)
      end

      it "reschedules the job with the snooze counter incremented" do
        worker.perform(serialized_context)
        expect(described_class).to have_received(:perform_in).with(5.0, serialized_context, nil, 1)
      end

      it "carries the snooze counter forward across reschedules" do
        worker.perform(serialized_context, nil, 3)
        expect(described_class).to have_received(:perform_in).with(5.0, serialized_context, nil, 4)
      end
    end

    context "when semaphore acquisition fails" do
      before do
        allow(executor).to receive(:resume_execution)
          .and_raise(RubyReactor::Semaphore::AcquisitionError)
        allow(described_class).to receive(:perform_in)
      end

      it "reschedules the job" do
        worker.perform(serialized_context)
        expect(described_class).to have_received(:perform_in).with(5.0, serialized_context, nil, 1)
      end
    end

    context "when rate limit is exceeded" do
      let(:error) do
        RubyReactor::RateLimit::ExceededError.new(
          "rate limit hit",
          retry_after_seconds: 2,
          key_base: "api",
          limit: 3,
          period_seconds: 1,
          period_name: "second"
        )
      end

      before do
        allow(executor).to receive(:resume_execution).and_raise(error)
        allow(described_class).to receive(:perform_in)
      end

      it "uses the error's retry_after_seconds as the snooze delay" do
        worker.perform(serialized_context)
        expect(described_class).to have_received(:perform_in).with(2.0, serialized_context, nil, 1)
      end

      it "floors very short retry_after at 0.1s" do
        tiny = RubyReactor::RateLimit::ExceededError.new(
          "rate limit hit",
          retry_after_seconds: 0.01,
          key_base: "api",
          limit: 3,
          period_seconds: 1,
          period_name: "second"
        )
        allow(executor).to receive(:resume_execution).and_raise(tiny)

        worker.perform(serialized_context)
        expect(described_class).to have_received(:perform_in).with(0.1, serialized_context, nil, 1)
      end
    end

    context "when snooze attempts are exhausted" do
      let(:adapter) { instance_double(RubyReactor::Storage::RedisAdapter) }

      before do
        RubyReactor.configuration.lock_snooze_max_attempts = 3
        allow(executor).to receive(:resume_execution)
          .and_raise(RubyReactor::Lock::AcquisitionError, "lock busy")
        allow(context).to receive(:status=)
        allow(context).to receive(:failure_reason=)
        # Escalation now advances the ordered-lock cursor; a non-ordered-lock
        # reactor simply has no stash, so info_from returns nil and skips it.
        allow(context).to receive(:private_data).and_return({})
        allow(RubyReactor::ContextSerializer).to receive(:serialize).and_return("{serialized}")
        allow(RubyReactor.configuration).to receive(:storage_adapter).and_return(adapter)
        allow(adapter).to receive(:store_context)
        allow(RubyReactor.configuration.logger).to receive(:warn)
        allow(described_class).to receive(:perform_in)
      end

      it "does not reschedule" do
        worker.perform(serialized_context, nil, 3)
        expect(described_class).not_to have_received(:perform_in)
      end

      it "marks the context as failed and persists it" do
        worker.perform(serialized_context, nil, 3)

        expect(context).to have_received(:status=).with(:failed)
        expect(context).to have_received(:failure_reason=).with(
          hash_including(
            exception_class: "RubyReactor::Lock::AcquisitionError",
            snooze_attempts: 3
          )
        )
        expect(adapter).to have_received(:store_context).with("test-execution-id", "{serialized}", "TestReactor")
      end
    end

    # rubocop:disable RSpec/MultipleMemoizedHelpers
    context "when deserialization fails" do
      let(:adapter) { instance_double(RubyReactor::Storage::RedisAdapter) }
      let(:error) { RubyReactor::Error::DeserializationError.new("globalid gem missing") }
      let(:raw_blob) do
        JSON.generate(
          "schema_version" => RubyReactor::ContextSerializer::SCHEMA_VERSION,
          "context_id" => "ctx-broken",
          "reactor_class" => "BrokenReactor"
        )
      end

      before do
        allow(RubyReactor::ContextSerializer).to receive(:deserialize).and_raise(error)
        allow(RubyReactor.configuration).to receive(:storage_adapter).and_return(adapter)
        allow(adapter).to receive(:store_context)
        allow(RubyReactor.configuration.logger).to receive(:error)
      end

      it "does not raise and returns nil" do
        expect(worker.perform(raw_blob)).to be_nil
      end

      it "does not call the executor" do
        worker.perform(raw_blob)
        expect(RubyReactor::Executor).not_to have_received(:new)
      end

      it "logs the failure" do
        worker.perform(raw_blob)
        expect(RubyReactor.configuration.logger).to have_received(:error)
          .with(a_string_including("ctx-broken", "DeserializationError", "globalid gem missing"))
      end

      it "persists a failed-status context payload" do
        worker.perform(raw_blob)

        expect(adapter).to have_received(:store_context) do |context_id, payload, reactor_class_name|
          expect(context_id).to eq("ctx-broken")
          expect(reactor_class_name).to eq("BrokenReactor")
          parsed = JSON.parse(payload)
          expect(parsed["status"]).to eq("failed")
          expect(parsed["failure_reason"]["exception_class"]).to eq("RubyReactor::Error::DeserializationError")
          expect(parsed["failure_reason"]["message"]).to include("globalid gem missing")
        end
      end

      it "prefers the reactor_class_name argument over the one embedded in the blob" do
        worker.perform(raw_blob, "OverrideReactor")
        expect(adapter).to have_received(:store_context).with("ctx-broken", anything, "OverrideReactor")
      end

      it "skips persistence when context_id cannot be extracted" do
        worker.perform("not-json-at-all")
        expect(adapter).not_to have_received(:store_context)
      end

      it "also catches SchemaVersionError" do
        allow(RubyReactor::ContextSerializer).to receive(:deserialize)
          .and_raise(RubyReactor::Error::SchemaVersionError.new("0.9"))
        expect { worker.perform(raw_blob) }.not_to raise_error
      end

      it "swallows storage failures so the original error is not masked" do
        allow(adapter).to receive(:store_context).and_raise(StandardError, "redis down")
        expect { worker.perform(raw_blob) }.not_to raise_error
        expect(RubyReactor.configuration.logger).to have_received(:error)
          .with(a_string_including("failed to persist"))
      end
    end

    # rubocop:enable RSpec/MultipleMemoizedHelpers

    context "when OrderedLock::WaitError is raised" do
      let(:error) do
        RubyReactor::OrderedLock::WaitError.new(
          key: "txs:42",
          nonce: 7,
          last_completed: 4,
          retry_after_seconds: 3
        )
      end

      before do
        RubyReactor.configuration.lock_snooze_base_delay = 0.5
        RubyReactor.configuration.lock_snooze_jitter = 0
        allow(executor).to receive(:resume_execution).and_raise(error)
        allow(described_class).to receive(:perform_in)
      end

      it "snoozes at the base delay, NOT the poison-pill retry_after" do
        # retry_after_seconds (3s here) is the poison-pill window — the upper
        # bound before a dead blocker is force-advanced, not how long a live
        # blocker takes. Using it as the re-poll interval would make every
        # out-of-order nonce sleep the full window. Re-poll at the base delay.
        worker.perform(serialized_context)
        expect(described_class).to have_received(:perform_in).with(0.5, serialized_context, nil, 1)
      end

      it "bypasses the snooze cap — keeps rescheduling past lock_snooze_max_attempts" do
        RubyReactor.configuration.lock_snooze_max_attempts = 3
        # Above the cap; for Lock/Semaphore this would escalate. WaitError must reschedule.
        worker.perform(serialized_context, nil, 99)
        expect(described_class).to have_received(:perform_in).with(0.5, serialized_context, nil, 100)
      end

      it "does NOT mark the context as failed even past the cap" do
        RubyReactor.configuration.lock_snooze_max_attempts = 3
        allow(context).to receive(:status=)
        allow(context).to receive(:failure_reason=)
        worker.perform(serialized_context, nil, 99)
        expect(context).not_to have_received(:status=).with(:failed)
      end
    end

    context "with jitter configured" do
      before do
        RubyReactor.configuration.lock_snooze_jitter = 5
        allow(executor).to receive(:resume_execution).and_raise(RubyReactor::Lock::AcquisitionError)
        allow(described_class).to receive(:perform_in)
      end

      it "schedules within the [base, base + jitter] window" do
        worker.perform(serialized_context)
        expect(described_class).to have_received(:perform_in) do |delay, *_rest|
          expect(delay).to be_between(5.0, 10.0)
        end
      end
    end
  end
end
