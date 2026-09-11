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
    %i[run undo compensate].each do |action|
      it "translates fail! inside ##{action} into a Failure from the class-level call, not UncaughtThrowError" do
        step = Class.new(described_class)
        step.define_method(action) { fail!("nope") }

        result = case action
                 when :run then step.run({}, context)
                 when :undo then step.undo(nil, {}, context)
                 when :compensate then step.compensate("reason", {}, context)
                 end

        expect(result).to be_a(RubyReactor::Failure)
        expect(result.error).to eq("nope")
      end
    end

    it "translates success!/skip!/halt! from #run" do
      success_step = Class.new(described_class) { def run = success!(:ok) }
      skip_step = Class.new(described_class) { def run = skip!(:skipped_value) }
      halt_step = Class.new(described_class) { def run = halt!(reason: "stop") }

      expect(success_step.run({}, context)).to be_a(RubyReactor::Success)
      expect(skip_step.run({}, context)).to be_a(RubyReactor::Skipped)
      expect(halt_step.run({}, context)).to be_a(RubyReactor::Halt)
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
end
