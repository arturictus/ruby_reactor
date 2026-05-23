# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Enhanced Error Reporting" do
  let(:context) do
    # Use constant if available or string if needed but constant preferred for verified doubles
    reactor_double = class_double(RubyReactor::Reactor, name: "TestReactor", inputs: {}, return_step: nil)
    RubyReactor::Context.new({}, reactor_double)
  end

  let(:step_failure) do
    original_error = StandardError.new("Original Error").tap do |e|
      e.set_backtrace(["/path/to/file.rb:11:in `foo'", "/path/to/file.rb:20:in `bar'"])
    end

    RubyReactor::Error::StepFailureError.new(
      "Step failed",
      step: :test_step,
      context: context,
      original_error: original_error,
      step_arguments: {}
    )
  end

  let(:compensation_manager) { instance_double(RubyReactor::Executor::CompensationManager) }
  let(:dependency_graph) { instance_double(RubyReactor::DependencyGraph) }
  let(:result_handler) do
    RubyReactor::Executor::ResultHandler.new(
      context: context,
      compensation_manager: compensation_manager,
      dependency_graph: dependency_graph
    )
  end

  before do
    allow(compensation_manager).to receive(:rollback_completed_steps)
    # Mock CodeExtractor to avoid File.read on fake paths
    allow(RubyReactor::Utils::CodeExtractor).to receive(:extract).and_return([
                                                                               { line_number: 10, content: "def foo",
                                                                                 target: false },
                                                                               { line_number: 11,
                                                                                 content: "  raise 'error'",
                                                                                 target: true },
                                                                               { line_number: 12, content: "end",
                                                                                 target: false }
                                                                             ])
  end

  describe "ResultHandler#handle_execution_error" do
    let(:step_failure) do
      original_error = StandardError.new("Original Error").tap do |e|
        e.set_backtrace(["/path/to/file.rb:11:in `foo'", "/path/to/file.rb:20:in `bar'"])
      end

      RubyReactor::Error::StepFailureError.new(
        "Step failed",
        step: :test_step,
        context: context,
        original_error: original_error,
        step_arguments: {}
      )
    end

    it "extracts file path and line number from original error backtrace" do
      failure = result_handler.handle_execution_error(step_failure)

      expect(failure.file_path).to eq("/path/to/file.rb")
      expect(failure.line_number).to eq(11)
      expect(failure.exception_class).to eq("StandardError")
    end

    it "includes code snippet in the failure object" do
      failure = result_handler.handle_execution_error(step_failure)

      expect(failure.code_snippet).to be_an(Array)
      expect(failure.code_snippet.length).to eq(3)
      expect(failure.code_snippet[1][:target]).to be true
      expect(failure.code_snippet[1][:content]).to eq("  raise 'error'")
    end

    it "persists error details in failure message" do
      failure = result_handler.handle_execution_error(step_failure)
      message = failure.message

      expect(message).to include("Location: /path/to/file.rb:11")
      expect(message).to include("Code Snippet:")
      expect(message).to include(">   11    raise 'error'")
    end

    it "extracts location from Ruby 3.x single-quoted backtrace lines" do
      original_error = StandardError.new("Random error triggered!").tap do |e|
        e.set_backtrace(
          ["/workspace/demo_app/app/reactors/ar_map_reactor.rb:48:in 'block (3 levels) in <class:ArMapReactor>'"]
        )
      end

      error = RubyReactor::Error::StepFailureError.new(
        "Step failed",
        step: :ramdomly_fail,
        context: context,
        original_error: original_error,
        step_arguments: {}
      )

      failure = result_handler.handle_execution_error(error)

      expect(failure.file_path).to eq("/workspace/demo_app/app/reactors/ar_map_reactor.rb")
      expect(failure.line_number).to eq(48)
      expect(failure.code_snippet).to be_an(Array)
    end
  end
end
