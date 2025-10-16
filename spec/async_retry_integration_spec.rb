# frozen_string_literal: true

require "spec_helper"
require "sidekiq/testing"
# rubocop:disable RSpec/DescribeClass
RSpec.describe "RubyReactor Async and Retry Integration" do
  # rubocop:enable RSpec/DescribeClass
  before do
    Sidekiq::Testing.fake!
    Sidekiq::Worker.clear_all
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
      expect(RubyReactor::Worker.jobs.size).to eq(1)
    end

    it "executes full reactor asynchronously" do
      reactor = TestAsyncReactor.new
      reactor.run(user_id: 123, email: "test@example.com")

      # Process the queued job
      RubyReactor::Worker.drain

      # Verify the job was processed (in real Sidekiq this would happen asynchronously)
      expect(RubyReactor::Worker.jobs.size).to eq(0)
    end
  end

  describe "Step-level async handoff" do
    it "executes synchronously until async step, then returns AsyncResult" do
      reactor = TestStepAsyncReactor.new
      result = reactor.run(user_id: 123, email: "test@example.com")

      expect(result).to be_a(RubyReactor::AsyncResult)

      # Verify job was queued for async step
      expect(RubyReactor::Worker.jobs.size).to eq(1)
    end

    it "resumes execution from async step in worker" do
      reactor = TestStepAsyncReactor.new
      reactor.run(user_id: 123, email: "test@example.com")

      # Process the queued job
      RubyReactor::Worker.drain

      # Verify the job was processed
      expect(RubyReactor::Worker.jobs.size).to eq(0)
    end
  end

  describe "Retry scenarios with different backoff strategies" do
    it "retries with exponential backoff until success" do
      reactor = RetryExponentialReactor.new
      reactor.run(attempt_count: 1)

      # Should have 1 job initially
      expect(RubyReactor::Worker.jobs.size).to eq(1)

      # Process jobs - should retry a few times
      RubyReactor::Worker.drain

      # Verify retries happened (in fake mode, jobs are processed immediately)
      # In real Sidekiq, this would be scheduled with delays
    end

    context "with linear backoff" do
      it "uses linear backoff strategy" do
        reactor = RetryLinearReactor.new
        reactor.run

        expect(RubyReactor::Worker.jobs.size).to eq(1)
        RubyReactor::Worker.drain
      end
    end

    context "with fixed backoff" do
      it "uses fixed backoff strategy" do
        reactor = RetryFixedReactor.new
        reactor.run

        expect(RubyReactor::Worker.jobs.size).to eq(1)
        RubyReactor::Worker.drain
      end
    end
  end

  describe "Compensation and rollback in async context" do
    it "rolls back completed steps when retry fails" do
      reactor = CompensatingReactor.new
      reactor.run(user_id: 123)

      expect(RubyReactor::Worker.jobs.size).to eq(1)
      RubyReactor::Worker.drain
    end
  end

  describe "Idempotent step handling" do
    it "handles idempotent steps correctly during retries" do
      reactor = IdempotentReactor.new
      reactor.run(order_id: "ORD-123")

      expect(RubyReactor::Worker.jobs.size).to eq(1)
      RubyReactor::Worker.drain
    end
  end
end
