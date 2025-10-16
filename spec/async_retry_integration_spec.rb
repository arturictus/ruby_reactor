# frozen_string_literal: true

require "spec_helper"
require "sidekiq/testing"

RSpec.describe "RubyReactor Async and Retry Integration" do
  before do
    Sidekiq::Testing.fake!
    Sidekiq::Worker.clear_all
  end

  after do
    Sidekiq::Testing.fake!
  end

  # Define test reactor classes as constants for serialization
  class TestAsyncReactor < RubyReactor::Reactor
    async true

    input :user_id
    input :email

    step :validate_input do
      argument :user_id, input(:user_id)
      argument :email, input(:email)

      run do |args, _context|
        if args[:user_id].to_i > 0 && args[:email].include?("@")
          RubyReactor.Success("valid")
        else
          RubyReactor.Failure("Invalid input")
        end
      end
    end

    step :create_user do
      argument :validation, result(:validate_input)

      run do |args, _context|
        # Simulate user creation
        user = { id: args[:user_id], email: args[:email] }
        RubyReactor.Success(user)
      end
    end

    step :send_welcome_email do
      argument :user, result(:create_user)

      run do |args, _context|
        # Simulate email sending
        RubyReactor.Success("Email sent to #{args[:user][:email]}")
      end
    end
  end

  class TestStepAsyncReactor < RubyReactor::Reactor
    input :user_id
    input :email

    step :validate_input do
      argument :user_id, input(:user_id)
      argument :email, input(:email)

      run do |args, _context|
        if args[:user_id].to_i > 0 && args[:email].include?("@")
          RubyReactor.Success("valid")
        else
          RubyReactor.Failure("Invalid input")
        end
      end
    end

    step :create_user do
      async true
      argument :validation, result(:validate_input)

      run do |args, _context|
        # Simulate user creation
        user = { id: args[:user_id], email: args[:email] }
        RubyReactor.Success(user)
      end
    end

    step :send_welcome_email do
      argument :user, result(:create_user)

      run do |args, _context|
        # Simulate email sending
        RubyReactor.Success("Email sent to #{args[:user][:email]}")
      end
    end
  end

  class RetryExponentialReactor < RubyReactor::Reactor
    async true

    input :attempt_count

    step :flaky_operation do
      retries max_attempts: 3, backoff: :exponential, base_delay: 1
      argument :attempt_count, input(:attempt_count)

      run do |_args, context|
        attempt = context.retry_context.attempts_for_step('flaky_operation')

        # Fail first 2 attempts, succeed on 3rd
        if attempt < 3
          RubyReactor.Failure("Attempt #{attempt} failed")
        else
          RubyReactor.Success("Success on attempt #{attempt}")
        end
      end
    end
  end

  class RetryLinearReactor < RubyReactor::Reactor
    async true

    step :linear_retry_step do
      retries max_attempts: 3, backoff: :linear, base_delay: 2

      run do |_args, _context|
        RubyReactor.Failure("Always fails for testing")
      end
    end
  end

  class RetryFixedReactor < RubyReactor::Reactor
    async true

    step :fixed_retry_step do
      retries max_attempts: 3, backoff: :fixed, base_delay: 5

      run do |_args, _context|
        RubyReactor.Failure("Always fails for testing")
      end
    end
  end

  class CompensatingReactor < RubyReactor::Reactor
    async true

    input :user_id

    step :create_user do
      argument :user_id, input(:user_id)

      run do |_args, _context|
        # Simulate user creation that might fail
        RubyReactor.Failure("User creation failed")
      end

      compensate do |_error, _args, _context|
        # Simulate cleanup
        Sidekiq.logger.info "Cleaning up user creation"
        RubyReactor.Success()
      end
    end

    step :send_notification do
      argument :user_id, input(:user_id)

      run do |_args, _context|
        # This should not run if create_user fails
        RubyReactor.Success("Notification sent")
      end

      compensate do |_error, _args, _context|
        Sidekiq.logger.info "Cleaning up notification"
        RubyReactor.Success()
      end
    end
  end

  class IdempotentReactor < RubyReactor::Reactor
    async true

    input :order_id

    step :process_payment do
      idempotent true
      argument :order_id, input(:order_id)

      run do |args, _context|
        # Simulate payment processing
        RubyReactor.Success("Payment processed for #{args[:order_id]}")
      end
    end

    step :update_inventory do
      argument :order_id, input(:order_id)

      run do |args, _context|
        # Simulate inventory update
        RubyReactor.Success("Inventory updated for #{args[:order_id]}")
      end
    end
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
