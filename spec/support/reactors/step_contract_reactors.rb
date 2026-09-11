# frozen_string_literal: true

# Fixtures for step input contracts on the worker paths. Loaded by both the
# spec process and the live sidekiq worker (spec/support/sidekiq_boot.rb).
module StepContractFixtures
  # What the `:confirm` reader received from the worker. The reader runs in
  # the calling process, so this is observable even when the worker is a
  # separate sidekiq process.
  def self.received
    @received ||= []
  end

  def self.reset!
    @received = []
  end
end

class ContractChargeStep
  include RubyReactor::Step

  input :amount, :integer, gteq?: 1
  input :currency, :string, included_in?: %w[USD EUR]

  def self.run(args, _context)
    RubyReactor.Success(args)
  end
end

class ContractAsyncStepReactor < RubyReactor::Reactor
  input :amount
  input :currency

  async_step :charge, ContractChargeStep do
    argument :amount, input(:amount)
    argument :currency, input(:currency)
    retries max_attempts: 3
  end

  step :confirm do
    argument :charge, result(:charge)
    run do |args|
      StepContractFixtures.received << args[:charge]
      args[:charge].is_a?(RubyReactor::Failure) ? args[:charge] : RubyReactor.Success(args[:charge])
    end
  end

  returns :confirm
end

class ContractBackgroundReactor < RubyReactor::Reactor
  background all: true

  input :amount
  input :currency

  step :charge, ContractChargeStep do
    argument :amount, input(:amount)
    argument :currency, input(:currency)
  end

  returns :charge
end

class ContractInlineAsyncReactor < RubyReactor::Reactor
  input :amount
  input :currency

  async_step :charge do
    inputs do
      input :amount, :integer, gteq?: 1
      input :currency, :string, included_in?: %w[USD EUR]
    end

    argument :amount, input(:amount)
    argument :currency, input(:currency)
    run { |args, _context| RubyReactor.Success(args) }
  end

  step :confirm do
    argument :charge, result(:charge)
    run do |args|
      StepContractFixtures.received << args[:charge]
      args[:charge].is_a?(RubyReactor::Failure) ? args[:charge] : RubyReactor.Success(args[:charge])
    end
  end

  returns :confirm
end

# No `argument` lines: the worker process must see the inferred wiring too.
class ContractNameResolvedAsyncReactor < RubyReactor::Reactor
  input :amount
  input :currency

  async_step :charge, ContractChargeStep

  step :confirm do
    argument :charge, result(:charge)
    run do |args|
      StepContractFixtures.received << args[:charge]
      args[:charge].is_a?(RubyReactor::Failure) ? args[:charge] : RubyReactor.Success(args[:charge])
    end
  end

  returns :confirm
end
