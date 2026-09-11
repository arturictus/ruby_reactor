# frozen_string_literal: true

require "spec_helper"

# US4: parent-first contract merging and body overriding survive the move to
# a real class hierarchy with `inherited` deleted (data-model.md — contract
# ivars are already per-class, so there is nothing left for `inherited` to
# reset). Regression guard, not a red spec by design.
RSpec.describe "Step contract inheritance across subclasses" do
  before do
    stub_const("BaseStep", Class.new(RubyReactor::Step) do
      input :a, :integer
    end)
    stub_const("ChildStep", Class.new(BaseStep) do
      input :b, :integer

      def run = Success(sum: inputs[:a] + inputs[:b])
    end)
  end

  it "raises naming the missing parent input when the child omits it" do
    expect { ChildStep.run({ b: 2 }, nil) }
      .to raise_error(RubyReactor::Error::InputValidationError) { |e| expect(e.field_errors).to have_key(:a) }
  end

  it "runs the child's body with both the parent's and its own inputs" do
    result = ChildStep.run({ a: 1, b: 2 }, nil)

    expect(result).to be_success
    expect(result.value).to eq(sum: 3)
  end

  it "still validates before an overriding grandchild's body runs" do
    stub_const("GrandchildStep", Class.new(ChildStep) do
      def run = Success(:overridden)
    end)

    expect { GrandchildStep.run({ a: 1, b: "not an integer" }, nil) }
      .to raise_error(RubyReactor::Error::InputValidationError) { |e| expect(e.field_errors).to have_key(:b) }
    expect(GrandchildStep.run({ a: 1, b: 2 }, nil).value).to eq(:overridden)
  end

  it "gives the child both declarations and leaves the parent's untouched" do
    expect(ChildStep.input_contract.declarations.keys).to eq(%i[a b])
    expect(BaseStep.input_contract.declarations.keys).to eq([:a])
  end
end
