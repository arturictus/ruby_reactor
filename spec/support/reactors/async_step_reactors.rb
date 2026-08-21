# frozen_string_literal: true

# Fixtures for `async_step` (US2). Each reactor records what ran and where, so
# the specs can assert the dispatch/continue interleaving directly.
module AsyncStepFixtures
  def self.log
    @log ||= []
  end

  def self.reset!
    @log = []
  end

  def self.record(entry)
    log << entry
    entry
  end
end

# The headline case: :send_email is dispatched, :do_something_same_thread does
# NOT wait for it, and :check_email does.
class AsyncStepSiblingReactor < RubyReactor::Reactor
  input :email

  async_step :send_email do
    argument :to, input(:email)
    run do |args|
      AsyncStepFixtures.record([:send_email, args[:to]])
      RubyReactor.Success("sent:#{args[:to]}")
    end
  end

  step :do_something_same_thread do
    run do
      AsyncStepFixtures.record([:do_something_same_thread, nil])
      RubyReactor.Success(:done)
    end
  end
end

class AsyncStepReaderReactor < RubyReactor::Reactor
  input :email

  async_step :send_email do
    argument :to, input(:email)
    run { |args| RubyReactor.Success({ delivered_to: args[:to] }) }
  end

  step :check_email do
    argument :email, result(:send_email)
    run do |args|
      AsyncStepFixtures.record([:check_email, args[:email]])
      RubyReactor.Success(args[:email])
    end
  end

  returns :check_email
end

# A failing async step with NO reader: the parent must not compensate.
class AsyncStepFailingNoReaderReactor < RubyReactor::Reactor
  def self.compensated
    @compensated ||= []
  end

  def self.reset!
    @compensated = []
  end

  step :setup do
    run { RubyReactor.Success(:ready) }
    compensate do |_reason, _args, _ctx|
      AsyncStepFailingNoReaderReactor.compensated << :setup
      RubyReactor.Success()
    end
    undo do |_result, _args, _ctx|
      AsyncStepFailingNoReaderReactor.compensated << :setup
      RubyReactor.Success()
    end
  end

  async_step :risky do
    argument :setup, result(:setup)
    run { RubyReactor.Failure("async step blew up") }
  end
end

# The same failure, but a reader inspects it and opts into compensation.
class AsyncStepFailingWithReaderReactor < RubyReactor::Reactor
  def self.compensated
    @compensated ||= []
  end

  def self.reset!
    @compensated = []
  end

  step :setup do
    run { RubyReactor.Success(:ready) }
    compensate do |_reason, _args, _ctx|
      AsyncStepFailingWithReaderReactor.compensated << :setup
      RubyReactor.Success()
    end
    undo do |_result, _args, _ctx|
      AsyncStepFailingWithReaderReactor.compensated << :setup
      RubyReactor.Success()
    end
  end

  async_step :risky do
    argument :setup, result(:setup)
    run { RubyReactor.Failure("async step blew up") }
  end

  step :inspect_risky do
    argument :outcome, result(:risky)
    run do |args|
      AsyncStepFixtures.record([:inspect_risky, args[:outcome].class.name])
      args[:outcome].is_a?(RubyReactor::Failure) ? RubyReactor.Failure(args[:outcome].error) : RubyReactor.Success(:ok)
    end
  end
end

# Nothing ever completes this step's record, so a reader must hit the FR-005
# bound instead of hanging.
class AsyncStepNeverCompletesReactor < RubyReactor::Reactor
  async_step :never do
    run { RubyReactor.Success(:unreachable) }
  end

  step :reader do
    argument :value, result(:never)
    run { |args| RubyReactor.Success(args[:value]) }
  end
end

# An async_step declared AFTER the hand-off point: it is first reached inside
# the worker and must still get its own job there.
class AsyncStepAfterBackgroundReactor < RubyReactor::Reactor
  step :first do
    run { RubyReactor.Success(:first) }
  end

  async_step :dispatched_in_worker do
    argument :first, result(:first)
    run do
      AsyncStepFixtures.record([:dispatched_in_worker, nil])
      RubyReactor.Success(:ran)
    end
  end

  background after: :first
end
