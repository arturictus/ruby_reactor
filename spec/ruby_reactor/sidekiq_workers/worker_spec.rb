# frozen_string_literal: true

require "spec_helper"
require "sidekiq/testing"
require "ruby_reactor/sidekiq_workers/worker"

RSpec.describe RubyReactor::SidekiqWorkers::Worker do
  let(:context) { instance_double(RubyReactor::Context, context_id: "test-execution-id", reactor_class: reactor_class, inline_async_execution: true) }
  let(:reactor_class) { double("ReactorClass", name: "TestReactor") }
  let(:executor) { instance_double(RubyReactor::Executor) }
  let(:serialized_context) { "{}" }

  before do
    allow(RubyReactor::ContextSerializer).to receive(:deserialize).and_return(context)
    allow(RubyReactor::Executor).to receive(:new).and_return(executor)
    allow(executor).to receive(:save_context)
    allow(context).to receive(:inline_async_execution=)
    # Deterministic delay for assertions
    RubyReactor.configuration.lock_snooze_base_delay = 5
    RubyReactor.configuration.lock_snooze_jitter = 0
    RubyReactor.configuration.lock_snooze_max_attempts = 20
  end

  describe "#perform" do
    it "executes the reactor" do
      expect(executor).to receive(:resume_execution)
      subject.perform(serialized_context)
    end

    context "when lock acquisition fails" do
      before do
        allow(executor).to receive(:resume_execution).and_raise(RubyReactor::Lock::AcquisitionError)
      end

      it "reschedules the job with the snooze counter incremented" do
        expect(described_class).to receive(:perform_in).with(5.0, serialized_context, nil, 1)

        subject.perform(serialized_context)
      end

      it "carries the snooze counter forward across reschedules" do
        expect(described_class).to receive(:perform_in).with(5.0, serialized_context, nil, 4)

        subject.perform(serialized_context, nil, 3)
      end
    end

    context "when semaphore acquisition fails" do
      before do
        allow(executor).to receive(:resume_execution)
          .and_raise(RubyReactor::Semaphore::AcquisitionError)
      end

      it "reschedules the job" do
        expect(described_class).to receive(:perform_in).with(5.0, serialized_context, nil, 1)

        subject.perform(serialized_context)
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
      end

      it "uses the error's retry_after_seconds as the snooze delay" do
        expect(described_class).to receive(:perform_in).with(2.0, serialized_context, nil, 1)

        subject.perform(serialized_context)
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

        expect(described_class).to receive(:perform_in).with(0.1, serialized_context, nil, 1)
        subject.perform(serialized_context)
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
        allow(RubyReactor::ContextSerializer).to receive(:serialize).and_return("{serialized}")
        allow(RubyReactor.configuration).to receive(:storage_adapter).and_return(adapter)
        allow(adapter).to receive(:store_context)
        allow(RubyReactor.configuration.logger).to receive(:warn)
      end

      it "does not reschedule" do
        expect(described_class).not_to receive(:perform_in)
        subject.perform(serialized_context, nil, 3)
      end

      it "marks the context as failed and persists it" do
        expect(context).to receive(:status=).with(:failed)
        expect(context).to receive(:failure_reason=) do |reason|
          expect(reason).to include(
            exception_class: "RubyReactor::Lock::AcquisitionError",
            snooze_attempts: 3
          )
        end
        expect(adapter).to receive(:store_context).with("test-execution-id", "{serialized}", "TestReactor")

        subject.perform(serialized_context, nil, 3)
      end
    end

    context "with jitter configured" do
      before do
        RubyReactor.configuration.lock_snooze_jitter = 5
        allow(executor).to receive(:resume_execution).and_raise(RubyReactor::Lock::AcquisitionError)
      end

      it "schedules within the [base, base + jitter] window" do
        allow(described_class).to receive(:perform_in) do |delay, *_rest|
          expect(delay).to be_between(5.0, 10.0)
        end

        subject.perform(serialized_context)
      end
    end
  end
end
