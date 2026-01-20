# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyReactor::RSpec::TestSubject, "#mock_step" do
  # Define a simple reactor for testing
  class MockingTestReactor < RubyReactor::Reactor
    class AddOneStep
      include RubyReactor::Step

      def self.run(args, _context)
        RubyReactor::Success(value: args[:value] + 1)
      end
    end

    input :value

    step :step_one do
      run do |args, _context|
        RubyReactor::Success(value: args[:value] * 2)
      end
    end

    step :step_two, AddOneStep do
      argument :value, input(:value)
    end
  end

  subject(:test_subject) { test_reactor(MockingTestReactor, inputs: inputs) }

  let(:inputs) { { value: 10 } }

  context "without mocking" do
    it "runs correctly" do
      test_subject.run
      expect(test_subject).to be_success
      expect(test_subject.step_result(:step_one)).to eq(value: 20)
    end
  end

  context "when replacing functionality completely" do
    before do
      test_subject.mock_step(:step_one) do |_args, _context|
        RubyReactor::Success(value: 999)
      end
    end

    it "returns the mocked result" do
      test_subject.run
      expect(test_subject.step_result(:step_one)).to eq(value: 999)
    end
  end

  context "when calling original implementation" do
    before do
      test_subject.mock_step(:step_one) do |args, context, original|
        # Original doubles 10 -> 20
        result = original.call(args, context)
        # We add 5 -> 25
        RubyReactor::Success(value: result.value[:value] + 5)
      end
    end

    it "wraps the original result" do
      test_subject.run
      expect(test_subject).to be_success
      expect(test_subject.step_result(:step_one)).to eq(value: 25)
    end
  end

  context "when mocking a class-based step" do
    before do
      test_subject.mock_step(:step_two) do |args, context, original|
        # Original adds 1 -> 11 (if input was 10)
        # But wait, step_two gets output of step_one?
        # By default steps consume reactor inputs if not specified?
        # Re-checking StepBuilder... "args_to_pass = arguments.empty? ? @context.inputs : arguments"
        # Since we didn't chain steps, step_two gets reactor inputs { value: 10 }.
        # Original: 10 + 1 = 11.
        result = original.call(args, context)
        RubyReactor::Success(value: result.value[:value] * 10)
      end
    end

    it "correctly calls class-based original implementation" do
      test_subject.run
      # 11 * 10 = 110
      expect(test_subject.step_result(:step_two)).to eq(value: 110)
    end
  end

  context "when simulating failure" do
    before do
      test_subject.mock_step(:step_one) do |_, _, _|
        raise "Boom!"
      end
    end

    it "captures the failure" do
      test_subject.run
      expect(test_subject).to be_failure
      expect(test_subject.result.error).to include("Boom!")
    end
  end

  context "when modifying inputs to original" do
    before do
      test_subject.mock_step(:step_one) do |args, context, original|
        # Change input to 50
        modified_args = args.merge(value: 50)
        original.call(modified_args, context)
      end
    end

    it "runs original with modified arguments" do
      test_subject.run
      # Original doubles the input. 50 * 2 = 100.
      expect(test_subject.step_result(:step_one)).to eq(value: 100)
    end
  end
end
