# frozen_string_literal: true

# Fixtures for `async_reactor` (US3). Loaded by the live sidekiq worker too, so
# these stay free of any RSpec dependency.
module AsyncReactorFixtures
  def self.log
    @log ||= []
  end

  def self.compensated
    @compensated ||= []
  end

  def self.reset!
    @log = []
    @compensated = []
  end
end

class AsyncChildSucceedsReactor < RubyReactor::Reactor
  input :user_id

  step :create do
    argument :user_id, input(:user_id)
    run do |args|
      AsyncReactorFixtures.log << [:child_create, args[:user_id]]
      RubyReactor.Success({ account_id: "acct-#{args[:user_id]}" })
    end
  end

  returns :create
end

class AsyncChildFailsReactor < RubyReactor::Reactor
  input :user_id

  step :create do
    argument :user_id, input(:user_id)
    run do
      AsyncReactorFixtures.log << [:child_failed, nil]
      RubyReactor.Failure("child could not create the profile")
    end
  end
end

class AsyncChildRequiringEmailReactor < RubyReactor::Reactor
  input :email, :string, format?: /@/

  step :notify do
    argument :email, input(:email)
    run { |args| RubyReactor.Success(args[:email]) }
  end
end

# Fire-and-forget: nothing reads the child's result, so its failure must never
# reach the parent's compensation path.
class AsyncReactorFireAndForgetReactor < RubyReactor::Reactor
  input :user_id

  step :setup do
    run { RubyReactor.Success(:ready) }
    compensate do
      AsyncReactorFixtures.compensated << :setup
      RubyReactor.Success()
    end
    undo do
      AsyncReactorFixtures.compensated << :setup
      RubyReactor.Success()
    end
  end

  async_reactor :create_profile, AsyncChildFailsReactor do
    argument :user_id, input(:user_id)
  end
end

# Awaited: a later step reads the child's outcome and decides.
class AsyncReactorAwaitedReactor < RubyReactor::Reactor
  input :user_id

  async_reactor :create_account, AsyncChildSucceedsReactor do
    argument :user_id, input(:user_id)
  end

  step :verify_all do
    argument :account, result(:create_account)
    run do |args|
      AsyncReactorFixtures.log << [:verify_all, args[:account].class.name]
      args[:account].success? ? RubyReactor.Success(args[:account].value) : RubyReactor.Failure(args[:account].error)
    end
  end

  returns :verify_all
end

# Same shape, but the child fails — the reader's explicit Failure is what opts
# the parent into compensation.
class AsyncReactorAwaitedFailingReactor < RubyReactor::Reactor
  input :user_id

  step :setup do
    run { RubyReactor.Success(:ready) }
    compensate do
      AsyncReactorFixtures.compensated << :setup
      RubyReactor.Success()
    end
    undo do
      AsyncReactorFixtures.compensated << :setup
      RubyReactor.Success()
    end
  end

  async_reactor :create_profile, AsyncChildFailsReactor do
    argument :user_id, input(:user_id)
  end

  step :verify do
    argument :setup, result(:setup)
    argument :profile, result(:create_profile)
    run do |args|
      AsyncReactorFixtures.log << [:verify, args[:profile].class.name]
      args[:profile].success? ? RubyReactor.Success(:ok) : RubyReactor.Failure(args[:profile].error)
    end
  end
end

# Child and parent resolve to the SAME exclusive key.
class AsyncLockedChildReactor < RubyReactor::Reactor
  input :account_id

  with_lock(ttl: 30) { |inputs| "account:#{inputs[:account_id]}" }

  step :work do
    run { RubyReactor.Success(:done) }
  end
end

class AsyncSemaphoreChildReactor < RubyReactor::Reactor
  input :account_id

  with_semaphore(limit: 1) { |inputs| "account:#{inputs[:account_id]}" }

  step :work do
    run { RubyReactor.Success(:done) }
  end
end

class AsyncDifferentKeyChildReactor < RubyReactor::Reactor
  input :account_id

  with_lock(ttl: 30) { |inputs| "audit:#{inputs[:account_id]}" }

  step :work do
    run { RubyReactor.Success(:done) }
  end
end

class AsyncReactorLockCollisionReactor < RubyReactor::Reactor
  input :account_id

  with_lock(ttl: 30) { |inputs| "account:#{inputs[:account_id]}" }

  async_reactor :child, AsyncLockedChildReactor do
    argument :account_id, input(:account_id)
  end
end

class AsyncReactorSemaphoreCollisionReactor < RubyReactor::Reactor
  input :account_id

  with_lock(ttl: 30) { |inputs| "account:#{inputs[:account_id]}" }

  async_reactor :child, AsyncSemaphoreChildReactor do
    argument :account_id, input(:account_id)
  end
end

class AsyncReactorDifferentKeyReactor < RubyReactor::Reactor
  input :account_id

  with_lock(ttl: 30) { |inputs| "account:#{inputs[:account_id]}" }

  async_reactor :child, AsyncDifferentKeyChildReactor do
    argument :account_id, input(:account_id)
  end
end

# The child's inputs are validated in the PARENT's process, at dispatch.
class AsyncReactorInvalidChildInputsReactor < RubyReactor::Reactor
  async_reactor :notify, AsyncChildRequiringEmailReactor do
    argument :email, value("not-an-email")
  end
end

class AsyncOrderedLockChildReactor < RubyReactor::Reactor
  input :queue

  with_ordered_lock(ttl: 30) { |inputs| "ordered:#{inputs[:queue]}" }

  step :work do
    run { RubyReactor.Success(:done) }
  end
end

class AsyncReactorOrderedChildReactor < RubyReactor::Reactor
  input :queue

  async_reactor :child, AsyncOrderedLockChildReactor do
    argument :queue, input(:queue)
  end
end

# A child that pauses at an interrupt is NOT terminal.
class AsyncPausingChildReactor < RubyReactor::Reactor
  input :user_id

  step :begin_work do
    run { RubyReactor.Success(:started) }
  end

  interrupt :await_approval do
    wait_for :begin_work
  end

  step :finish do
    argument :approval, result(:await_approval)
    run { RubyReactor.Success(:approved) }
  end

  returns :finish
end

class AsyncReactorPausingChildParentReactor < RubyReactor::Reactor
  input :user_id

  async_reactor :child, AsyncPausingChildReactor do
    argument :user_id, input(:user_id)
  end

  step :reader do
    argument :outcome, result(:child)
    run { |args| RubyReactor.Success(args[:outcome]) }
  end
end
