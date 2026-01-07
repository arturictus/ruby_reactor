# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe "Context Serialization Persistence" do
  let(:step_name) { :some_step }
  let(:attempt_data) { { interrupt_attempts: { some_step: 1 } } }

  it "preserves symbols round trip" do
    original_context = RubyReactor::Context.new
    original_context.private_data = attempt_data

    serialized = RubyReactor::ContextSerializer.serialize(original_context)

    # Simulate storage/retrieval via JSON
    stored_json = serialized

    restored_context = RubyReactor::ContextSerializer.deserialize(stored_json)

    puts "Original private_data: #{original_context.private_data.inspect}"
    puts "Restored private_data: #{restored_context.private_data.inspect}"

    expect(restored_context.private_data[:interrupt_attempts]).not_to be_nil
    expect(restored_context.private_data[:interrupt_attempts][:some_step]).to eq(1)
  end

  it "handles mixing string/symbol keys" do
    # Simulate what happens in Reactor#validate_continue_payload
    # @context.private_data[:interrupt_attempts] ||= {}
    # @context.private_data[:interrupt_attempts][step_name] ||= 0

    # If step_name is a symbol :some_step

    context = RubyReactor::Context.new
    context.private_data[:interrupt_attempts] = { some_step: 1 }

    serialized = RubyReactor::ContextSerializer.serialize(context)
    restored = RubyReactor::ContextSerializer.deserialize(serialized)

    # If step_name comes in as string "some_step" from generic API input?
    step_name_str = "some_step"

    # Accessing with string should fail if keys are symbols,
    # unless IndifferentAccess is used (which it isn't here by default)
    expect(restored.private_data[:interrupt_attempts][step_name_str]).to be_nil
    expect(restored.private_data[:interrupt_attempts][:some_step]).to eq(1)

    # If we write with string?
    context.private_data[:interrupt_attempts]["some_step"] = 2
    serialized_2 = RubyReactor::ContextSerializer.serialize(context)
    restored_2 = RubyReactor::ContextSerializer.deserialize(serialized_2)

    expect(restored_2.private_data[:interrupt_attempts].keys).to include(:some_step)
  end
end
