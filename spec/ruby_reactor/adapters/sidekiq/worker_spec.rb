# frozen_string_literal: true

require "spec_helper"
require "sidekiq/testing"
require "ruby_reactor/adapters/sidekiq/worker"

# The worker fans many collaborators (storage, serializer, executor, context,
# router) into one unit, so the suite needs more memoized helpers than the cop's
# default; the alternative (re-stubbing in every example) is worse.
# rubocop:disable RSpec/MultipleMemoizedHelpers
RSpec.describe RubyReactor::Adapters::Sidekiq::Worker do
  subject(:worker) { described_class.new }

  let(:reactor_class) { Class.new { def self.name = "TestReactor" } }
  let(:context_id) { "test-execution-id" }
  let(:reactor_class_name) { "TestReactor" }
  let(:context) do
    instance_double(
      RubyReactor::Context,
      context_id: context_id,
      reactor_class: reactor_class,
      inline_async_execution: true
    )
  end
  let(:executor) { instance_double(RubyReactor::Executor) }
  let(:adapter) { instance_double(RubyReactor::Storage::RedisAdapter) }
  # Non-nil stored payload; deserialize_hash is stubbed to return the context
  # double, so its shape does not matter beyond "present".
  let(:stored_data) { { "context_id" => context_id, "schema_version" => "1.0" } }

  before do
    allow(RubyReactor.configuration).to receive(:storage_adapter).and_return(adapter)
    allow(adapter).to receive(:retrieve_context).with(context_id, reactor_class_name).and_return(stored_data)
    allow(adapter).to receive(:store_context)
    allow(RubyReactor::ContextSerializer).to receive(:deserialize_hash).and_return(context)
    allow(RubyReactor::Executor).to receive(:new).and_return(executor)
    allow(executor).to receive(:checkpoint!)
    allow(executor).to receive(:skip_context_persist?).and_return(false)
    allow(context).to receive(:inline_async_execution=)
    # Deterministic delay for assertions
    RubyReactor.configuration.lock_snooze_base_delay = 5
    RubyReactor.configuration.lock_snooze_jitter = 0
    RubyReactor.configuration.lock_snooze_max_attempts = 20
  end

  describe "#perform" do
    it "rehydrates by id and resumes the reactor" do
      allow(executor).to receive(:resume_execution)
      worker.perform(context_id, reactor_class_name)
      expect(executor).to have_received(:resume_execution)
    end

    it "returns nil without resuming when storage has no context (swept/expired)" do
      allow(adapter).to receive(:retrieve_context).with(context_id, reactor_class_name).and_return(nil)
      expect(worker.perform(context_id, reactor_class_name)).to be_nil
      expect(RubyReactor::Executor).not_to have_received(:new)
    end

    context "when lock acquisition fails" do
      before do
        allow(executor).to receive(:resume_execution).and_raise(RubyReactor::Lock::AcquisitionError)
        allow(described_class).to receive(:perform_in)
      end

      it "reschedules the job by id with the snooze counter incremented" do
        worker.perform(context_id, reactor_class_name)
        expect(described_class).to have_received(:perform_in).with(5.0, context_id, reactor_class_name, 1)
      end

      it "carries the snooze counter forward across reschedules" do
        worker.perform(context_id, reactor_class_name, 3)
        expect(described_class).to have_received(:perform_in).with(5.0, context_id, reactor_class_name, 4)
      end
    end

    context "when semaphore acquisition fails" do
      before do
        allow(executor).to receive(:resume_execution)
          .and_raise(RubyReactor::Semaphore::AcquisitionError)
        allow(described_class).to receive(:perform_in)
      end

      it "reschedules the job" do
        worker.perform(context_id, reactor_class_name)
        expect(described_class).to have_received(:perform_in).with(5.0, context_id, reactor_class_name, 1)
      end
    end

    context "when the per-context liveness lock is contended" do
      before do
        allow(executor).to receive(:resume_execution).and_raise(
          RubyReactor::Lock::ContextLockContention.new("busy", context_lock_key: "async:#{context_id}")
        )
        allow(described_class).to receive(:perform_in)
      end

      it "reschedules without ever escalating, even past the cap" do
        RubyReactor.configuration.lock_snooze_max_attempts = 3
        allow(context).to receive(:status=)
        worker.perform(context_id, reactor_class_name, 99)
        expect(described_class).to have_received(:perform_in).with(5.0, context_id, reactor_class_name, 100)
        expect(context).not_to have_received(:status=).with(:failed)
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
        worker.perform(context_id, reactor_class_name)
        expect(described_class).to have_received(:perform_in).with(2.0, context_id, reactor_class_name, 1)
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

        worker.perform(context_id, reactor_class_name)
        expect(described_class).to have_received(:perform_in).with(0.1, context_id, reactor_class_name, 1)
      end
    end

    context "when snooze attempts are exhausted" do
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
        allow(RubyReactor.configuration.logger).to receive(:warn)
        allow(described_class).to receive(:perform_in)
      end

      it "does not reschedule" do
        worker.perform(context_id, reactor_class_name, 3)
        expect(described_class).not_to have_received(:perform_in)
      end

      it "marks the context as failed and persists it" do
        worker.perform(context_id, reactor_class_name, 3)

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

    context "when deserialization fails" do
      let(:error) { RubyReactor::Error::DeserializationError.new("globalid gem missing") }
      let(:context_id) { "ctx-broken" }
      let(:reactor_class_name) { "BrokenReactor" }

      before do
        allow(RubyReactor::ContextSerializer).to receive(:deserialize_hash).and_raise(error)
        allow(RubyReactor.configuration.logger).to receive(:error)
      end

      it "does not raise and returns nil" do
        expect(worker.perform(context_id, reactor_class_name)).to be_nil
      end

      it "does not call the executor" do
        worker.perform(context_id, reactor_class_name)
        expect(RubyReactor::Executor).not_to have_received(:new)
      end

      it "logs the failure" do
        worker.perform(context_id, reactor_class_name)
        expect(RubyReactor.configuration.logger).to have_received(:error)
          .with(a_string_including("ctx-broken", "DeserializationError", "globalid gem missing"))
      end

      it "persists a failed-status context payload keyed by the job's id and class" do
        worker.perform(context_id, reactor_class_name)

        expect(adapter).to have_received(:store_context) do |id, payload, name|
          expect(id).to eq("ctx-broken")
          expect(name).to eq("BrokenReactor")
          parsed = JSON.parse(payload)
          expect(parsed["status"]).to eq("failed")
          expect(parsed["failure_reason"]["exception_class"]).to eq("RubyReactor::Error::DeserializationError")
          expect(parsed["failure_reason"]["message"]).to include("globalid gem missing")
        end
      end

      it "also catches SchemaVersionError" do
        allow(RubyReactor::ContextSerializer).to receive(:deserialize_hash)
          .and_raise(RubyReactor::Error::SchemaVersionError.new("0.9"))
        expect { worker.perform(context_id, reactor_class_name) }.not_to raise_error
      end

      it "swallows storage failures so the original error is not masked" do
        allow(adapter).to receive(:store_context).and_raise(StandardError, "redis down")
        expect { worker.perform(context_id, reactor_class_name) }.not_to raise_error
        expect(RubyReactor.configuration.logger).to have_received(:error)
          .with(a_string_including("failed to persist"))
      end
    end

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
        worker.perform(context_id, reactor_class_name)
        expect(described_class).to have_received(:perform_in).with(0.5, context_id, reactor_class_name, 1)
      end

      it "bypasses the snooze cap — keeps rescheduling past lock_snooze_max_attempts" do
        RubyReactor.configuration.lock_snooze_max_attempts = 3
        worker.perform(context_id, reactor_class_name, 99)
        expect(described_class).to have_received(:perform_in).with(0.5, context_id, reactor_class_name, 100)
      end

      it "does NOT mark the context as failed even past the cap" do
        RubyReactor.configuration.lock_snooze_max_attempts = 3
        allow(context).to receive(:status=)
        allow(context).to receive(:failure_reason=)
        worker.perform(context_id, reactor_class_name, 99)
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
        worker.perform(context_id, reactor_class_name)
        expect(described_class).to have_received(:perform_in) do |delay, *_rest|
          expect(delay).to be_between(5.0, 10.0)
        end
      end
    end
  end
end
# rubocop:enable RSpec/MultipleMemoizedHelpers
