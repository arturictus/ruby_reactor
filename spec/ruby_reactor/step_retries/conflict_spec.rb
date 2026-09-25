# frozen_string_literal: true

require "spec_helper"

# US4: a step's policy is declared in ONE place (FR-009), like locks.
RSpec.describe "Step retries: one declaration per step" do
  let(:failing_run) { ->(_step) { RubyReactor.Failure("x") } }

  it "refuses `retries` in the step block when the class declares it too" do
    stub_const("ConflictSpecCharge", Class.new(RubyReactor::Step) { retries max_attempts: 3 })

    expect do
      Class.new(RubyReactor::Reactor) do
        step(:charge, ConflictSpecCharge) { retries max_attempts: 5 }
      end
    end.to raise_error(
      RubyReactor::Error::ValidationError,
      /step :charge declares `retries` inline, but ConflictSpecCharge declares it too.*subclass/m
    )
  end

  it "refuses it when the class's policy is inherited from a parent" do
    stub_const("ConflictSpecBase", Class.new(RubyReactor::Step) { retries max_attempts: 3 })
    stub_const("ConflictSpecChild", Class.new(ConflictSpecBase))

    expect do
      Class.new(RubyReactor::Reactor) do
        step(:charge, ConflictSpecChild) { retries max_attempts: 5 }
      end
    end.to raise_error(RubyReactor::Error::ValidationError, /ConflictSpecChild declares it too/)
  end

  it "accepts a step-block `retries` for a class that declares none" do
    step_class = Class.new(RubyReactor::Step)

    expect do
      Class.new(RubyReactor::Reactor) do
        step(:charge, step_class) { retries max_attempts: 5 }
      end
    end.not_to raise_error
  end

  it "does not retry a class declaring `retries max_attempts: 1`" do
    run_body = failing_run
    step_class = Class.new(RubyReactor::Step) do
      retries max_attempts: 1

      define_method(:run) { run_body.call(self) }
    end
    reactor = Class.new(RubyReactor::Reactor) { step :charge, step_class }.new
    reactor.run({})

    expect(reactor.context.retry_context.attempts_for_step(:charge)).to eq(1)
  end
end
