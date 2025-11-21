# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Nested Reactor Inline Execution" do
  it "correctly merges state when running inline with nested reactors" do
    # Mock async_router to run inline and return the executor
    allow(RubyReactor.configuration.async_router).to receive(:perform_async) do |serialized_context, reactor_class_name|
      # Simulate inline execution
      worker = RubyReactor::Worker.new
      worker.perform(serialized_context, reactor_class_name)
    end
    reactor = Support::NestedInlineRootReactor.new

    result = reactor.run(id: "123")

    expect(result).to be_a(RubyReactor::Success)
    # The result of the root reactor is a hash of all step results
    expect(result.value[:child_process][:async_step]).to eq("async_done_123")
    expect(result.value[:prepare]).to eq("prepared")
  end

  it "correctly merges state when running inline with multiple composed reactors" do
    # Mock async_router to run inline and return the executor
    allow(RubyReactor.configuration.async_router).to receive(:perform_async) do |serialized_context, reactor_class_name|
      # Simulate inline execution
      worker = RubyReactor::Worker.new
      worker.perform(serialized_context, reactor_class_name)
    end

    result = Support::MultipleComposeRootReactor.run(id: "root")

    expect(result).to be_a(RubyReactor::Success)
    expect(result.value[:first_step]).to eq("first_step_done")
    expect(result.value[:child_1][:async_step]).to eq("async_done_child_1")
    expect(result.value[:child_2][:async_step]).to eq("async_done_child_2")
    expect(result.value[:last_step]).to eq("last_step_done")
  end
end
