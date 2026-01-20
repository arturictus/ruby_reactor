# frozen_string_literal: true

require "spec_helper"

# rubocop:disable RSpec/MultipleMemoizedHelpers
RSpec.describe "Failure Reporting" do
  let(:context) { RubyReactor::Context.new }
  let(:compensation_manager) { instance_double(RubyReactor::Executor::CompensationManager, rollback_completed_steps: nil) }
  let(:dependency_graph) { instance_double(RubyReactor::DependencyGraph) }
  # Mock ReactorClass properly
  let(:reactor_class_double) { class_double(RubyReactor::Reactor, name: "TestReactor") }
  # Mock Executor to avoid full initialization if not needed, or pass correct args
  # But Executor.new needs real class or good mock.
  let(:executor) { RubyReactor::Executor.new(reactor_class_double, {}, context) }
  let(:result_handler) do
    RubyReactor::Executor::ResultHandler.new(
      context: context,
      compensation_manager: compensation_manager,
      dependency_graph: dependency_graph
    )
  end

  describe "RubyReactor::Failure" do
    it "captures exception_class from an error object" do
      error = StandardError.new("test error")
      failure = RubyReactor::Failure.new(error)
      expect(failure.exception_class).to eq("StandardError")
    end

    it "allows explicit exception_class" do
      failure = RubyReactor::Failure.new("error", exception_class: "CustomError")
      expect(failure.exception_class).to eq("CustomError")
    end

    it "is nil for string errors by default" do
      failure = RubyReactor::Failure.new("error")
      expect(failure.exception_class).to be_nil
    end
  end

  describe "Executor#update_context_status" do
    it "populates failure_reason with exception_class" do
      error = ArgumentError.new("invalid argument")
      failure = RubyReactor::Failure.new(error, step_name: "test_step")

      executor.send(:update_context_status, failure)

      expect(context.status).to eq(:failed)
      expect(context.failure_reason.exception_class).to eq("ArgumentError")
      expect(context.failure_reason.error.message).to eq("invalid argument")
    end
  end

  describe "ResultHandler#handle_execution_error" do
    it "extracts exception_class from StepFailureError" do
      original_error = RuntimeError.new("step failed")
      reactor_class = class_double(RubyReactor::Reactor, name: "MyReactor", inputs: {})
      # Mock context with necessary methods
      context_double = instance_double(
        RubyReactor::Context,
        inputs: {},
        reactor_class: reactor_class,
        :current_step= => nil,
        map_metadata: nil,
        context_id: "123"
      )

      step_error = RubyReactor::Error::StepFailureError.new(
        "wrapped message",
        step: "my_step",
        context: context_double,
        original_error: original_error
      )

      failure = result_handler.handle_execution_error(step_error)

      expect(failure).to be_a(RubyReactor::Failure)
      expect(failure.exception_class).to eq("RuntimeError")
    end

    it "extracts exception_class from general exceptions" do
      error = NameError.new("undefined local variable")

      failure = result_handler.handle_execution_error(error)

      expect(failure).to be_a(RubyReactor::Failure)
      expect(failure.exception_class).to eq("NameError")
    end
  end
end

# rubocop:enable RSpec/MultipleMemoizedHelpers
