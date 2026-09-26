# frozen_string_literal: true

require "spec_helper"

# Step code reads its inputs by method (`inputs.order_id`). A name the step
# can't read raises `UndeclaredInputError` on the line that reads it, instead
# of returning nil and failing somewhere else (specs/inputs_by_method.md).
RSpec.describe RubyReactor::Step::Inputs, type: :reactor do
  def contract(&block)
    RubyReactor::Step::InputContract.new(owner: "TestStep").tap { |c| c.instance_eval(&block) }
  end

  def build(values, contract: nil, owner: "OrderStep")
    described_class.new(values, contract: contract, owner: owner)
  end

  describe "reading" do
    let(:declared) do
      contract do
        input :order_guid
        input :note, optional: true
        input :paid, optional: true
        input :select, optional: true
      end
    end

    it "returns a declared value, nil for an absent optional, and false as false" do
      inputs = build({ order_guid: 42, paid: false }, contract: declared)

      expect(inputs.order_guid).to eq(42)
      expect(inputs.note).to be_nil
      expect(inputs.paid).to be(false)
    end

    it "reads string-keyed values" do
      expect(build({ "order_guid" => 42 }, contract: declared).order_guid).to eq(42)
    end

    it "reads a declared name that clashes with a private Kernel method" do
      expect(build({ order_guid: 1, select: :all }, contract: declared).select).to eq(:all)
    end

    it "raises a non-retryable UndeclaredInputError naming the step and its declared inputs" do
      inputs = build({ order_guid: 42, order_id: 7 }, contract: declared)

      expect { inputs.order_id }.to raise_error(
        RubyReactor::Error::UndeclaredInputError,
        "OrderStep has no input :order_id. Declared inputs: :order_guid, :note, :paid, :select."
      ) { |e| expect(e.retryable?).to be(false) }
      expect(RubyReactor::Error::UndeclaredInputError.ancestors).to include(NoMethodError)
    end

    it "answers respond_to? for readable names only" do
      inputs = build({ order_guid: 42 }, contract: declared)

      expect(inputs).to respond_to(:order_guid)
      expect(inputs).to respond_to(:note)
      expect(inputs).not_to respond_to(:order_id)
    end

    it "reads the present keys when there is no contract" do
      inputs = build({ amount: 5, "currency" => "USD" })

      expect([inputs.amount, inputs.currency]).to eq([5, "USD"])
      expect { inputs.note }.to raise_error(
        RubyReactor::Error::UndeclaredInputError, "OrderStep has no input :note. Declared inputs: :amount, :currency."
      )
    end

    it "says `none` when nothing is readable" do
      expect { build({}).x }.to raise_error(/Declared inputs: none\./)
    end

    it "falls back to present keys for a contract with only cross-field rules" do
      rules_only = contract { validate_inputs { required(:amount).filled } }

      expect(build({ amount: 5 }, contract: rules_only).amount).to eq(5)
    end
  end

  describe "as a whole" do
    let(:declared) do
      contract do
        input :order_guid
        input :card, redact: true
        input :note, optional: true
      end
    end

    let(:inputs) { build({ order_guid: 42, "card" => "4242", extra: 1 }, contract: declared) }

    it "to_h has the supplied readable names only, with symbol keys" do
      expect(inputs.to_h).to eq(order_guid: 42, card: "4242")
    end

    it "splats with **" do
      expect({ **inputs }).to eq(order_guid: 42, card: "4242")
    end

    it "redacts in inspect" do
      expect(inputs.inspect).to eq({ order_guid: 42, card: "[REDACTED]" }.inspect)
    end

    it "is frozen and has no []" do
      expect(inputs).to be_frozen
      expect { inputs[:order_guid] }.to raise_error(RubyReactor::Error::UndeclaredInputError)
    end

    it "wraps another Inputs" do
      expect(build(inputs, contract: declared).to_h).to eq(inputs.to_h)
    end
  end

  describe "reserved names" do
    it "rejects an input the reader object already answers publicly" do
      expect { Class.new(RubyReactor::Step) { input :method } }
        .to raise_error(RubyReactor::Error::ValidationError, /input :method/)
    end
  end

  describe "in step code" do
    let(:seen) { [] }

    it "is what class run, undo and compensate receive" do
      log = seen
      stub_const("ReserveStep", Class.new(RubyReactor::Step) do
        input :sku
        define_method(:run) { (log << [:run, inputs.class, inputs.sku]) && Success(:ok) }
        define_method(:undo) { (log << [:undo, inputs.class, inputs.sku]) && Success() }
      end)
      stub_const("ChargeStep", Class.new(RubyReactor::Step) do
        input :sku
        define_method(:run) { Failure("declined") }
        define_method(:compensate) { (log << [:compensate, inputs.class, inputs.sku]) && Success() }
      end)
      reactor = Class.new(RubyReactor::Reactor) do
        input :sku
        step :reserve, ReserveStep
        step(:charge, ChargeStep) { wait_for :reserve }
      end

      expect(reactor.run(sku: "A1")).to be_failure
      expect(seen).to eq([[:run, described_class, "A1"], [:compensate, described_class, "A1"],
                          [:undo, described_class, "A1"]])
    end

    it "is what inline run, undo and compensate blocks receive" do
      log = seen
      reactor = Class.new(RubyReactor::Reactor) do
        input :sku
        step :reserve do
          argument :sku, input(:sku)
          run { |inputs| (log << [:run, inputs.class, inputs.sku]) && Success(:ok) }
          undo { |_result, inputs| (log << [:undo, inputs.class, inputs.sku]) && Success() }
        end
        step :charge do
          argument :sku, input(:sku)
          wait_for :reserve
          run { Failure("declined") }
          compensate { |_error, inputs| (log << [:compensate, inputs.class, inputs.sku]) && Success() }
        end
      end

      expect(reactor.run(sku: "A1")).to be_failure
      expect(seen).to eq([[:run, described_class, "A1"], [:compensate, described_class, "A1"],
                          [:undo, described_class, "A1"]])
    end

    it "lets an unwired inline step with an inputs block read only what it declares" do
      reactor = Class.new(RubyReactor::Reactor) do
        input :amount
        input :secret
        step :charge do
          inputs { input :amount }
          run { |inputs| Success(inputs.secret) }
        end
      end

      result = reactor.run(amount: 5, secret: "s")

      expect(result).to be_failure
      expect(result.error.to_s).to include("step :charge has no input :secret. Declared inputs: :amount.")
    end

    it "surfaces a typo in compensate as a rollback failure naming the input" do
      reactor = Class.new(RubyReactor::Reactor) do
        input :sku
        step :charge do
          argument :sku, input(:sku)
          run { Failure("declined") }
          compensate { |_error, inputs| inputs.skew && Success() }
        end
      end

      result = reactor.run(sku: "A1")

      expect(result.rollback_failures).to contain_exactly(
        hash_including(step: :charge, kind: :compensate, message: a_string_including("no input :skew"))
      )
    end

    it "does not retry a typo" do
      attempts = []
      stub_const("TypoStep", Class.new(RubyReactor::Step) do
        input :order_guid
        retries max_attempts: 3, backoff: :fixed, base_delay: 0
        define_method(:run) { (attempts << 1) && Success(inputs.order_id) }
      end)
      reactor = Class.new(RubyReactor::Reactor) do
        input :order_guid
        step :validate, TypoStep
      end

      result = reactor.run(order_guid: 1)

      expect(result).to be_failure
      expect(result.error.to_s).to include("TypoStep has no input :order_id. Declared inputs: :order_guid.")
      expect(attempts.size).to eq(1)
    end
  end

  describe "returned from a step" do
    it "is stored and validated as a Hash, so result(:step, :key) reads it" do
      reactor = Class.new(RubyReactor::Reactor) do
        input :sku
        step :echo do
          argument :sku, input(:sku)
          run { |inputs| Success(inputs) }
          validate_output { required(:sku).filled(:string) }
        end
        step :read do
          argument :sku, result(:echo, :sku)
          argument :echoed, result(:echo)
          run { |inputs| Success([inputs.sku, inputs.echoed]) }
        end
        returns :read
      end

      expect(reactor.run(sku: "A1").value).to eq(["A1", { sku: "A1" }])
    end
  end

  describe "handed on from a step body" do
    it "is accepted by another step's .run" do
      stub_const("InnerStep", Class.new(RubyReactor::Step) do
        input :sku
        input :qty, optional: true, default: 1
        define_method(:run) { Success([inputs.sku, inputs.qty]) }
      end)
      stub_const("OuterStep", Class.new(RubyReactor::Step) do
        input :sku
        define_method(:run) { InnerStep.run(inputs, context) }
      end)

      expect(OuterStep.run(sku: "A1").value).to eq(["A1", 1])
    end

    it "is accepted by the original a TestSubject mock calls" do
      stub_const("DoubleStep", Class.new(RubyReactor::Step) do
        input :value
        define_method(:run) { Success(inputs.value * 2) }
      end)
      stub_const("DoubleReactor", Class.new(RubyReactor::Reactor) do
        input :value
        step :double, DoubleStep
        returns :double
      end)

      subject = test_reactor(DoubleReactor, { value: 10 }).mock_step(:double) do |inputs, ctx, original|
        RubyReactor.Success(original.call(inputs, ctx).value + inputs.value)
      end

      subject.run
      expect(subject.step_result(:double)).to eq(30)
    end
  end
end
