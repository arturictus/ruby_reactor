# frozen_string_literal: true

require "spec_helper"

# US1 on the synchronous execution paths. Inputs are wired with explicit
# `argument` lines throughout: name-based resolution is US4.
RSpec.describe "Step input contract enforcement" do
  let(:calls) { [] }

  let(:reactor) do
    stub_const("ChargeReactor", Class.new(RubyReactor::Reactor) do
      input :amount
      input :currency

      step :charge, ChargeStep do
        argument :amount, input(:amount)
        argument :currency, input(:currency)
      end

      returns :charge
    end)
  end

  before do
    sink = calls
    step = Class.new(RubyReactor::Step) do
      input :amount, :integer, gteq?: 1
      input :currency, :string, included_in?: %w[USD EUR]

      define_method(:run) do
        sink << inputs
        Success(inputs)
      end
    end
    stub_const("ChargeStep", step)
  end

  describe "acceptance scenarios" do
    it "runs the step with conforming values (AS1)" do
      result = reactor.run(amount: 5, currency: "USD")

      expect(result).to be_success
      expect(calls).to eq([{ amount: 5, currency: "USD" }])
    end

    it "fails before the body with step-attributed field errors (AS2)" do
      result = reactor.run(amount: 0, currency: "JPY")

      expect(result).to be_failure
      expect(result.validation_errors).to include(:amount, :currency)
      expect(result.step_name).to eq(:charge)
      expect(result.reactor_name).to eq("ChargeReactor")
      expect(calls).to be_empty
    end

    it "lets an optional input be absent (AS3)" do
      sink = calls
      stub_const("NoteStep", Class.new(RubyReactor::Step) do
        input :note, :string, optional: true

        define_method(:run) do
          sink << inputs
          Success(inputs)
        end
      end)
      note_reactor = Class.new(RubyReactor::Reactor) do
        input :note, optional: true
        step(:note, NoteStep) { argument :note, input(:note) }
      end

      expect(note_reactor.run({})).to be_success
      expect(calls.first[:note]).to be_nil
    end

    it "rejects an instance of an unrelated class (AS4)" do
      stub_const("Account", Class.new)
      stub_const("AccountStep", Class.new(RubyReactor::Step) do
        input :account, Account

        def run = Success(inputs)
      end)
      account_reactor = Class.new(RubyReactor::Reactor) do
        input :account
        step(:load, AccountStep) { argument :account, input(:account) }
      end

      expect(account_reactor.run(account: Account.new)).to be_success
      expect(account_reactor.run(account: "not an account").validation_errors).to have_key(:account)
    end

    it "fails a cross-field rule when values are individually valid (AS5)" do
      range_contract = Class.new(Dry::Validation::Contract) do
        params do
          required(:min).filled(:integer)
          required(:max).filled(:integer)
        end

        rule(:max, :min) { key.failure("must be greater than min") if values[:max] <= values[:min] }
      end.new
      stub_const("RangeStep", Class.new(RubyReactor::Step) do
        input :min, :integer
        input :max, :integer
        validate_inputs range_contract

        def run = Success(inputs)
      end)
      range_reactor = Class.new(RubyReactor::Reactor) do
        input :min
        input :max
        step :range, RangeStep do
          argument :min, input(:min)
          argument :max, input(:max)
        end
      end

      expect(range_reactor.run(min: 1, max: 5)).to be_success
      expect(range_reactor.run(min: 5, max: 1).validation_errors).to eq(max: "must be greater than min")
    end

    it "treats false as provided for a required boolean (AS6)" do
      sink = calls
      stub_const("NotifyStep", Class.new(RubyReactor::Step) do
        input :notify, :bool

        define_method(:run) do
          sink << inputs
          Success(inputs[:notify])
        end
      end)
      notify_reactor = Class.new(RubyReactor::Reactor) do
        input :notify
        step(:notify, NotifyStep) { argument :notify, input(:notify) }
        returns :notify
      end

      result = notify_reactor.run(notify: false)

      expect(result).to be_success
      expect(result.value).to be(false)
      expect(calls).to eq([{ notify: false }])
    end
  end

  it "is matched by test_reactor + have_validation_error" do
    expect(test_reactor(reactor, { amount: 0, currency: "USD" })).to have_validation_error(:amount)
  end

  it "rolls back a completed prior step" do
    undone = []
    saga = Class.new(RubyReactor::Reactor) do
      input :amount
      input :currency

      step :reserve do
        run { RubyReactor.Success(:reserved) }
        undo do |_result, _args, _ctx|
          undone << :reserve
          RubyReactor.Success()
        end
      end

      step :charge, ChargeStep do
        argument :amount, input(:amount)
        argument :currency, input(:currency)
        wait_for :reserve
      end
    end

    expect(saga.run(amount: 0, currency: "USD")).to be_failure
    expect(undone).to eq([:reserve])
  end

  it "validates once and never attempts the body of a retrying step" do
    retrying = Class.new(RubyReactor::Reactor) do
      input :amount
      input :currency

      step :charge, ChargeStep do
        argument :amount, input(:amount)
        argument :currency, input(:currency)
        retries max_attempts: 3, base_delay: 0
      end
    end
    allow(ChargeStep.input_contract).to receive(:enforce!).and_call_original

    expect(retrying.run(amount: 0, currency: "USD")).to be_failure
    expect(ChargeStep.input_contract).to have_received(:enforce!).once
    expect(calls).to be_empty
  end

  it "raises the same field errors on a direct call, attributed to the class (SC-010)" do
    via_reactor = reactor.run(amount: 0, currency: "USD")

    expect { ChargeStep.run({ amount: 0, currency: "USD" }, RubyReactor::Context.new) }
      .to raise_error(RubyReactor::Error::InputValidationError) { |e|
        expect(e.step_name).to eq("ChargeStep")
        expect(e.field_errors).to eq(via_reactor.validation_errors)
      }
  end

  it "reports an absent key as missing and a nil value as unfilled (contract §9)" do
    expect { ChargeStep.run({ amount: nil }, nil) }
      .to raise_error(RubyReactor::Error::InputValidationError) { |e|
        expect(e.field_errors).to eq(amount: "must be filled", currency: "is missing")
      }
  end

  describe "defaults" do
    before do
      sink = calls
      stub_const("GreetStep", Class.new(RubyReactor::Step) do
        input :greeting, optional: true, default: "x"

        define_method(:run) do
          sink << inputs[:greeting]
          Success(inputs)
        end
      end)
    end

    let(:greet_reactor) do
      Class.new(RubyReactor::Reactor) do
        input :greeting, optional: true
        step(:greet, GreetStep) { argument :greeting, input(:greeting) }
      end
    end

    it "applies for an absent key and for nil, never for false" do
      greet_reactor.run({})
      greet_reactor.run(greeting: nil)
      greet_reactor.run(greeting: false)
      GreetStep.run({}, nil)

      expect(calls).to eq(["x", "x", false, "x"])
    end
  end

  describe "redact: true" do
    before do
      stub_const("TokenStep", Class.new(RubyReactor::Step) do
        input :token, :string, redact: true, min_size?: 10
        input :amount, :integer

        def run = Success(inputs)
      end)
      stub_const("TokenReactor", Class.new(RubyReactor::Reactor) do
        input :token, redact: true
        input :amount
        step :pay, TokenStep do
          argument :token, input(:token)
          argument :amount, input(:amount)
        end
      end)
    end

    it "masks the value in step_arguments, the message and the execution trace" do
      result = TokenReactor.run(token: "sekrit", amount: 1)

      expect(result).to be_failure
      expect(result.step_arguments).to eq(token: "[REDACTED]", amount: 1)
      expect(result.message).to include("[REDACTED]")
      expect(result.message).not_to include("sekrit")

      trace = TokenReactor.find(result.execution_id).context.execution_trace
      run_entry = trace.find { |e| e[:type].to_s == "run" && e[:step].to_s == "pay" }
      expect(run_entry[:arguments]).to include(token: "[REDACTED]")
    end
  end

  it "fails a map when one element violates the contract" do
    stub_const("ChargeElementReactor", Class.new(RubyReactor::Reactor) do
      input :amount

      step :charge, ChargeStep do
        argument :amount, input(:amount)
        argument :currency, value("USD")
      end

      returns :charge
    end)
    stub_const("ChargeMapReactor", Class.new(RubyReactor::Reactor) do
      input :amounts

      map :charges, ChargeElementReactor do
        source input(:amounts)
        argument :amount, element(:charges)
      end
    end)

    result = ChargeMapReactor.run(amounts: [5, 0, 7])

    expect(result).to be_failure
    expect(calls.map { |a| a[:amount] }).not_to include(0)
  end

  it "does not validate a step whose where is false" do
    skipping = Class.new(RubyReactor::Reactor) do
      input :amount
      input :currency

      step :charge, ChargeStep do
        argument :amount, input(:amount)
        argument :currency, input(:currency)
        where { |_ctx| false }
      end
    end

    expect(skipping.run(amount: 0, currency: "USD")).to be_success
  end

  it "validates the same class under two step names independently" do
    twice = Class.new(RubyReactor::Reactor) do
      step :first_charge, ChargeStep do
        argument :amount, value(5)
        argument :currency, value("USD")
      end

      step :second_charge, ChargeStep do
        argument :amount, value(0)
        argument :currency, value("USD")
      end
    end

    result = twice.run({})

    expect(result.step_name).to eq(:second_charge)
    expect(calls).to eq([{ amount: 5, currency: "USD" }])
  end
end
