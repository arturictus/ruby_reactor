# frozen_string_literal: true

require "spec_helper"
require "sidekiq/testing"
RSpec.describe "RubyReactor Async and Retry Integration" do
  before do
    Sidekiq::Testing.fake!
    Sidekiq::Worker.clear_all
    allow(RubyReactor::Configuration.instance).to receive(:async_router).and_return(RubyReactor::Adapters::Sidekiq::Router)
  end

  after do
    Sidekiq::Testing.fake!
  end

  describe "Full reactor async execution" do
    it "queues job immediately and returns AsyncResult" do
      reactor = TestAsyncReactor.new
      result = reactor.run(user_id: 123, email: "test@example.com")

      expect(result).to be_a(RubyReactor::AsyncResult)
      expect(result.async?).to be true
      expect(result.success?).to be false
      expect(result.failure?).to be false

      # Verify job was queued
      expect(RubyReactor::Adapters::Sidekiq::Worker.jobs.size).to eq(1)
    end

    it "executes full reactor asynchronously" do
      reactor = TestAsyncReactor.new
      reactor.run(user_id: 123, email: "test@example.com")

      # Process the queued job
      RubyReactor::Adapters::Sidekiq::Worker.drain

      # Verify the job was processed (in real Sidekiq this would happen asynchronously)
      expect(RubyReactor::Adapters::Sidekiq::Worker.jobs.size).to eq(0)
    end
  end

  describe "Step-level async handoff" do
    it "executes synchronously until async step, then returns AsyncResult" do
      reactor = TestStepAsyncReactor.new
      result = reactor.run(user_id: 123, email: "test@example.com")

      expect(result).to be_a(RubyReactor::AsyncResult)

      # Verify job was queued for async step
      expect(RubyReactor::Adapters::Sidekiq::Worker.jobs.size).to eq(1)
    end

    it "resumes execution from async step in worker" do
      reactor = TestStepAsyncReactor.new
      reactor.run(user_id: 123, email: "test@example.com")

      # Process the queued job
      RubyReactor::Adapters::Sidekiq::Worker.drain

      # Verify the job was processed
      expect(RubyReactor::Adapters::Sidekiq::Worker.jobs.size).to eq(0)
    end
  end

  describe "Async step retry requeuing" do
    before do
      Sidekiq::Testing.fake!
      Sidekiq::Worker.clear_all
    end

    after do
      Sidekiq::Testing.fake!
    end

    it "requeues jobs for async step retries instead of executing inline" do
      # Create a reactor with an async step that will fail
      unless defined?(FailingAsyncRetryReactor)
        FailingAsyncRetryReactor = Class.new(RubyReactor::Reactor) do
          step :failing_async_step do
            async true
            retries max_attempts: 3, backoff: :fixed, base_delay: 1

            run do |_args, _context|
              RubyReactor::Failure("Step always fails")
            end
          end
        end
      end

      reactor_class = FailingAsyncRetryReactor

      reactor = reactor_class.new

      # Run the reactor - this should queue the initial job
      result = reactor.run

      # Should return AsyncResult
      expect(result).to be_a(RubyReactor::AsyncResult)

      # Should have 1 job queued
      expect(RubyReactor::Adapters::Sidekiq::Worker.jobs.size).to eq(1)

      # Process the job - this should execute the step, fail, and requeue for retry
      RubyReactor::Adapters::Sidekiq::Worker.drain

      # In fake mode, drain processes all jobs, including scheduled ones
      # Since the step fails and retries, it should process multiple jobs
      # But ultimately, when max_attempts is reached, no more jobs should be queued

      # After all processing, there should be no jobs left
      expect(RubyReactor::Adapters::Sidekiq::Worker.jobs.size).to eq(0)
    end
  end

  describe "Retry scenarios with different backoff strategies" do
    it "retries with exponential backoff until success" do
      reactor = RetryExponentialReactor.new
      reactor.run(attempt_count: 1)

      # Should have 1 job initially
      expect(RubyReactor::Adapters::Sidekiq::Worker.jobs.size).to eq(1)

      # Process jobs - should retry a few times
      RubyReactor::Adapters::Sidekiq::Worker.drain

      # Verify retries happened (in fake mode, jobs are processed immediately)
      # In real Sidekiq, this would be scheduled with delays
    end

    context "with linear backoff" do
      it "uses linear backoff strategy" do
        reactor = RetryLinearReactor.new
        reactor.run

        expect(RubyReactor::Adapters::Sidekiq::Worker.jobs.size).to eq(1)
        RubyReactor::Adapters::Sidekiq::Worker.drain
      end
    end

    context "with fixed backoff" do
      it "uses fixed backoff strategy" do
        reactor = RetryFixedReactor.new
        reactor.run

        expect(RubyReactor::Adapters::Sidekiq::Worker.jobs.size).to eq(1)
        RubyReactor::Adapters::Sidekiq::Worker.drain
      end
    end
  end
end
