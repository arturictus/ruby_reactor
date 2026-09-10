# frozen_string_literal: true

require "spec_helper"
require_relative "../examples/locking_reactors"

RSpec.describe "Halt status persistence" do
  before { SkippedStepCounters.reset }

  it "persists status halted for a halted run" do
    StepSkipReactor.run(should_skip: true)

    reactor_class_name = RubyReactor.reactor_storage_name(StepSkipReactor)
    adapter = RubyReactor.configuration.storage_adapter
    row = adapter.scan_reactors.find { |r| r[:class] == reactor_class_name }

    expect(row[:status]).to eq("halted")
  end

  it "reads a legacy status of skipped back as halted" do
    context = RubyReactor::Context.new({ should_skip: true }, StepSkipReactor)
    context.status = "skipped"
    adapter = RubyReactor.configuration.storage_adapter
    reactor_class_name = RubyReactor.reactor_storage_name(StepSkipReactor)
    adapter.store_context(context.context_id, RubyReactor::ContextSerializer.serialize(context), reactor_class_name)

    row = adapter.scan_reactors.find { |r| r[:id] == context.context_id }
    expect(row[:status]).to eq("halted")
  end

  it "leaves completed steps' effects in place after a halt (no compensation)" do
    StepSkipReactor.run(should_skip: true)

    expect(SkippedStepCounters.first_ran).to eq(1)
    expect(SkippedStepCounters.undo_count).to eq(0)
  end
end
