require "rails_helper"

RSpec.describe ParentReactor, type: :reactor do
  subject(:reactor) { test_reactor(described_class, inputs) }

  context "happy path" do
    let(:inputs) { { a: 2, b: 3 } }

    it "composes child reactors and produces formatted output" do
      expect(reactor).to be_success
      expect(reactor.result.value).to include("The sum is", "the Mul is")
    end

    it "executes the composed math_operation block" do
      expect(reactor).to have_run_step(:math_operation)
      expect(reactor).to have_run_step(:child_reactor)
      expect(reactor).to have_run_step(:format_result).after(:math_operation)
    end
  end

  context "when the composed child reactor fails" do
    let(:inputs) do
      { a: 1, b: 2, fail_at_reactor: :child_reactor, fail_at_step: :add }
    end

    it "fails the parent reactor and never runs format_result" do
      expect(reactor).to be_failure
      expect(reactor).not_to have_run_step(:format_result)
    end
  end

  context "input validation" do
    let(:inputs) { { a: "not-an-int", b: 1 } }

    it "fails with a validation error on :a" do
      expect(reactor).to be_failure
      expect(reactor).to have_validation_error(:a)
    end
  end
end
