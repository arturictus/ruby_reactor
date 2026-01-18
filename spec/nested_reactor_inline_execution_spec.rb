# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Nested Reactor Inline Execution" do
  it "correctly merges state when running inline with nested reactors" do
    Sidekiq::Testing.inline! do
      reactor = Support::NestedInlineRootReactor.new
      result = reactor.run(id: "123")

      # Need to reload result if it returned AsyncResult initially (though inline! usually prevents this)
      if result.is_a?(RubyReactor::AsyncResult)
        result = Support::NestedInlineRootReactor.find(result.execution_id).result
      end

      expect(result).to be_a(RubyReactor::Success)
      # The result of the root reactor is a hash of all step results
      expect(result.value[:child_process][:async_step]).to eq("async_done_123")
      expect(result.value[:prepare]).to eq("prepared")
    end
  end

  it "correctly merges state when running inline with multiple composed reactors" do
    Sidekiq::Testing.inline! do
      result = Support::MultipleComposeRootReactor.run(id: "root")

      if result.is_a?(RubyReactor::AsyncResult)
        result = Support::MultipleComposeRootReactor.find(result.execution_id).result
      end

      expect(result).to be_a(RubyReactor::Success)
      expect(result.value[:first_step]).to eq("first_step_done")
      expect(result.value[:child1][:async_step]).to eq("async_done_child1")
      expect(result.value[:child2][:async_step]).to eq("async_done_child2")
      expect(result.value[:last_step]).to eq("last_step_done")
    end
  end
end
