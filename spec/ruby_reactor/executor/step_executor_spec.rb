# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyReactor::Executor::StepExecutor do
  describe "argument resolution optimization" do
    let(:reactor_class) do
      Class.new(RubyReactor::Reactor) do
        input :value

        step :my_step do
          argument :arg1, input(:value)

          run do |args, _context|
            Success(args[:arg1])
          end
        end

        returns :my_step
      end
    end

    it "resolves step arguments only once during execute_step" do
      # Spy on resolve_arguments method
      expect_any_instance_of(described_class)
        .to receive(:resolve_arguments)
        .once
        .and_call_original

      result = reactor_class.run(value: "test_value")
      expect(result).to be_a(RubyReactor::Success)
      expect(result.value).to eq("test_value")
    end
  end
end
