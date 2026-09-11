# frozen_string_literal: true

require "spec_helper"

# The lifecycle contract for RubyReactor::Step as a base class, per
# data-model.md and contracts/step-lifecycle.md. This file cannot load while
# RubyReactor::Step is still a mixin module (T004 makes it a class).
RSpec.describe RubyReactor::Step do
  let(:context) { RubyReactor::Context.new({}) }

  describe "authoring and invocation (scenario a)" do
    it "runs the body with validated inputs and the context available as readers" do
      step = Class.new(described_class) do
        input :n, :integer

        def run
          Success(seen_n: inputs[:n], seen_context: context)
        end
      end

      result = step.run({ n: 5 }, context)

      expect(result).to be_success
      expect(result.value).to eq(seen_n: 5, seen_context: context)
    end
  end

  describe ".call (scenario b)" do
    it "is an alias of .run" do
      step = Class.new(described_class) do
        def run = Success(:ran)
      end

      expect(step.call({}, context).value).to eq(step.run({}, context).value)
      expect(step.method(:call).original_name).to eq(:run)
    end
  end

  describe "input validation (scenario c)" do
    it "raises InputValidationError with step_name set and never runs the body" do
      ran = false
      step = Class.new(described_class) do
        input :n, :integer
      end
      step.define_method(:run) do
        ran = true
        Success()
      end
      stub_const("ViolatingStep", step)

      expect { step.run({ n: "not an integer" }, context) }
        .to raise_error(RubyReactor::Error::InputValidationError) { |e| expect(e.step_name).to eq("ViolatingStep") }
      expect(ran).to be(false)
    end
  end

  describe "no declared inputs (scenario d)" do
    it "receives arbitrary arguments unchanged" do
      step = Class.new(described_class) do
        def run = Success(inputs)
      end

      result = step.run({ anything: 1, goes: 2 }, context)

      expect(result.value).to eq(anything: 1, goes: 2)
    end
  end

  describe "signal translation (scenario e)" do
    def invoke(step, action)
      case action
      when :run then step.run({}, context)
      when :undo then step.undo(nil, {}, context)
      when :compensate then step.compensate("reason", {}, context)
      end
    end

    %i[run undo compensate].each do |action|
      it "translates fail! inside ##{action} into a Failure from the class-level call, not UncaughtThrowError" do
        step = Class.new(described_class)
        step.define_method(action) { fail!("nope") }

        result = invoke(step, action)

        expect(result).to be_an_instance_of(RubyReactor::Failure)
        expect(result.error).to eq("nope")
      end
    end

    # Exact classes: Skipped < Success, so `be_a(Success)` would let a
    # success!/skip! mix-up through.
    {
      success!: [-> { success!(:ok) }, RubyReactor::Success],
      skip!: [-> { skip!(:skipped_value) }, RubyReactor::Skipped],
      halt!: [-> { halt!(reason: "stop") }, RubyReactor::Halt]
    }.each do |signal, (body, wrapper)|
      %i[run undo compensate].each do |action|
        it "translates #{signal} inside ##{action} into exactly #{wrapper}" do
          step = Class.new(described_class)
          step.define_method(action, &body)

          expect(invoke(step, action)).to be_an_instance_of(wrapper)
        end
      end
    end
  end

  describe "default undo/compensate (scenario f)" do
    it "return Skipped when omitted" do
      step = Class.new(described_class) do
        def run = Success()
      end

      expect(step.undo(nil, {}, context)).to be_a(RubyReactor::Skipped)
      expect(step.compensate("reason", {}, context)).to be_a(RubyReactor::Skipped)
    end
  end

  describe "omitted run (scenario g)" do
    it "raises NotImplementedError naming the subclass" do
      stub_const("BlankStep", Class.new(described_class))

      expect { BlankStep.run({}, context) }
        .to raise_error(NotImplementedError, /BlankStep/)
    end
  end

  describe "fresh instance per action (scenario h, D2)" do
    it "never leaks instance state set in #run into a later #undo on the same class" do
      stub_const("StatefulStep", Class.new(described_class) do
        def run
          @memo = :set_during_run
          Success()
        end

        def undo
          Success(memo: @memo)
        end
      end)

      StatefulStep.run({}, context)
      undo_result = StatefulStep.undo(nil, {}, context)

      expect(undo_result.value).to eq(memo: nil)
    end
  end

  describe "result/reason readers (scenario i)" do
    it "gives #undo the stored result and #compensate the failure reason" do
      step = Class.new(described_class) do
        def undo = Success(seen_result: result)
        def compensate = Success(seen_reason: reason)
      end

      expect(step.undo("stored result", {}, context).value).to eq(seen_result: "stored result")
      expect(step.compensate("boom", {}, context).value).to eq(seen_reason: "boom")
    end
  end

  describe "undo/compensate inputs" do
    let(:step) do
      Class.new(described_class) do
        input :amount, :integer
        input :currency, :string, optional: true, default: "USD"

        def run = Success(inputs)
        def undo = Success(inputs)
        def compensate = Success(inputs)
      end
    end

    it "are exactly the inputs #run saw, contract defaults included" do
      seen_by_run = step.run({ amount: 5 }, context).value

      expect(seen_by_run).to eq(amount: 5, currency: "USD")
      expect(step.undo(:stored, { amount: 5 }, context).value).to eq(seen_by_run)
      expect(step.compensate("boom", { amount: 5 }, context).value).to eq(seen_by_run)
    end

    it "are never checked against the contract, so rollback cannot raise on them" do
      expect(step.undo(:stored, { amount: "bad" }, context).value).to eq(amount: "bad", currency: "USD")
      expect(step.compensate("boom", { amount: "bad" }, context).value).to eq(amount: "bad", currency: "USD")
    end
  end
end
