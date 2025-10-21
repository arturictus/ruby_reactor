# frozen_string_literal: true

# rubocop:disable Lint/EmptyClass
# Mock reactor class for testing
class TestReactor
end
# rubocop:enable Lint/EmptyClass

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
        Success("valid")
      else
        Failure("Invalid input")
      end
    end
  end

  step :create_user do
    argument :validation, result(:validate_input)

    run do |args, _context|
      # Simulate user creation
      user = { id: args[:user_id], email: args[:email] }
      Success(user)
    end
  end

  step :send_welcome_email do
    argument :user, result(:create_user)

    run do |args, _context|
      # Simulate email sending
      Success("Email sent to #{args[:user][:email]}")
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
        Success("valid")
      else
        Failure("Invalid input")
      end
    end
  end

  step :create_user do
    async true
    argument :validation, result(:validate_input)

    run do |args, _context|
      # Simulate user creation
      user = { id: args[:user_id], email: args[:email] }
      Success(user)
    end
  end

  step :send_welcome_email do
    argument :user, result(:create_user)

    run do |args, _context|
      # Simulate email sending
      Success("Email sent to #{args[:user][:email]}")
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
      attempt = context.retry_context.attempts_for_step("flaky_operation")

      # Fail first 2 attempts, succeed on 3rd
      if attempt < 3
        Failure("Attempt #{attempt} failed")
      else
        Success("Success on attempt #{attempt}")
      end
    end
  end
end

class RetryLinearReactor < RubyReactor::Reactor
  async true

  step :linear_retry_step do
    retries max_attempts: 3, backoff: :linear, base_delay: 2

    run do |_args, _context|
      Failure("Always fails for testing")
    end
  end
end

class RetryFixedReactor < RubyReactor::Reactor
  async true

  step :fixed_retry_step do
    retries max_attempts: 3, backoff: :fixed, base_delay: 5

    run do |_args, _context|
      Failure("Always fails for testing")
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
      Failure("User creation failed")
    end

    compensate do |_error, _args, _context|
      # Simulate cleanup
      Sidekiq.logger.info "Cleaning up user creation"
      Success()
    end
  end

  step :send_notification do
    argument :user_id, input(:user_id)

    run do |_args, _context|
      # This should not run if create_user fails
      Success("Notification sent")
    end

    compensate do |_error, _args, _context|
      Sidekiq.logger.info "Cleaning up notification"
      Success()
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
      Success("Payment processed for #{args[:order_id]}")
    end
  end

  step :update_inventory do
    argument :order_id, input(:order_id)

    run do |args, _context|
      # Simulate inventory update
      Success("Inventory updated for #{args[:order_id]}")
    end
  end
end
