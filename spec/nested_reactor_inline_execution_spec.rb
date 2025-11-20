require "spec_helper"

RSpec.describe "Nested Reactor Inline Execution" do
  class NestedInlineChildReactor < RubyReactor::Reactor
    input :id

    step :async_step do
      async true
      run { |args, _| RubyReactor::Success("async_done_#{args[:id]}") }
    end
  end

  class NestedInlineRootReactor < RubyReactor::Reactor
    input :id

    step :prepare do
      run { |_, _| RubyReactor::Success("prepared") }
    end

    compose :child_process, NestedInlineChildReactor do
      argument :id, input(:id)
    end
  end

  it "correctly merges state when running inline with nested reactors" do
    # Mock async_router to run inline and return the executor
    allow(RubyReactor.configuration.async_router).to receive(:perform_async) do |serialized_context, reactor_class_name|
      # Simulate inline execution
      worker = RubyReactor::Worker.new
      worker.perform(serialized_context, reactor_class_name)
    end

    result = NestedInlineRootReactor.run(id: "123")

    expect(result).to be_a(RubyReactor::Success)
    # The result of the root reactor is a hash of all step results
    expect(result.value[:child_process][:async_step]).to eq("async_done_123")
    expect(result.value[:prepare]).to eq("prepared")
  end
end
