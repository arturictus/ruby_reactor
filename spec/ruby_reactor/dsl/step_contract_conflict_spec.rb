# frozen_string_literal: true

require "spec_helper"

# US2: for a step that owns its contract, `argument` is wiring only. Rules in
# the reactor, or wiring for an input the step never declares, fail when the
# `step` macro runs.
RSpec.describe "Reactor-side rules on a contract-owning step" do
  before do
    stub_const("ChargeStep", Class.new do
      include RubyReactor::Step

      input :amount, :integer, gteq?: 1

      def self.run(args, _) = RubyReactor.Success(args)
    end)
  end

  # Named before the body runs, so error messages can name the reactor.
  def define_reactor(&body)
    stub_const("ConflictReactor", Class.new(RubyReactor::Reactor))
    ConflictReactor.class_eval(&body)
    ConflictReactor
  end

  it "loads a mapping-only reactor and lets the step's contract govern (AS1)" do
    reactor = define_reactor do
      input :amount
      step(:charge, ChargeStep) { argument :amount, input(:amount) }
    end

    expect(reactor.run(amount: 5)).to be_success
    expect(reactor.run(amount: 0).validation_errors).to have_key(:amount)
  end

  it "accepts a transform, which is wiring" do
    reactor = define_reactor do
      input :cents
      step(:charge, ChargeStep) { argument :amount, input(:cents), transform: ->(c) { c / 100 } }
    end

    expect(reactor.run(cents: 500)).to be_success
    expect(reactor.run(cents: 50).validation_errors).to have_key(:amount)
  end

  it "rejects a typed argument, naming the reactor, step, argument and owning class (AS2)" do
    expect do
      define_reactor do
        input :amount
        step(:charge, ChargeStep) { argument :amount, input(:amount), :integer }
      end
    end.to raise_error(RubyReactor::Error::ValidationError, /ConflictReactor.*:charge.*:amount.*ChargeStep/m)
  end

  it "rejects a predicates-only argument" do
    expect do
      define_reactor do
        input :amount
        step(:charge, ChargeStep) { argument :amount, input(:amount), gt?: 0 }
      end
    end.to raise_error(RubyReactor::Error::ValidationError, /ConflictReactor.*:charge.*:amount.*ChargeStep/m)
  end

  it "rejects validate_args (AS3)" do
    expect do
      define_reactor do
        input :amount
        step :charge, ChargeStep do
          argument :amount, input(:amount)
          validate_args { required(:amount).filled(:integer) }
        end
      end
    end.to raise_error(RubyReactor::Error::ValidationError, /ConflictReactor.*:charge.*ChargeStep/m)
  end

  it "rejects wiring for an undeclared input (FR-018)" do
    expect do
      define_reactor do
        input :amount
        step :charge, ChargeStep do
          argument :amount, input(:amount)
          argument :bogus, value(1)
        end
      end
    end.to raise_error(RubyReactor::Error::ValidationError, /:charge.*:bogus.*Declared inputs: amount/m)
  end

  it "rejects a typed argument on an async_step the same way" do
    expect do
      define_reactor do
        input :amount
        async_step(:charge, ChargeStep) { argument :amount, input(:amount), :integer }
      end
    end.to raise_error(RubyReactor::Error::ValidationError, /ConflictReactor.*:charge.*:amount.*ChargeStep/m)
  end

  it "keeps reactor rules for a step class with no contract (AS4)" do
    stub_const("PlainStep", Class.new do
      include RubyReactor::Step

      def self.run(args, _) = RubyReactor.Success(args)
    end)

    reactor = nil
    expect do
      reactor = define_reactor do
        input :amount
        step(:charge, PlainStep) { argument :amount, input(:amount), :integer, gteq?: 1 }
      end
    end.not_to raise_error

    expect(reactor.run(amount: 5)).to be_success
    expect(reactor.run(amount: 0).validation_errors).to have_key(:amount)
  end
end
