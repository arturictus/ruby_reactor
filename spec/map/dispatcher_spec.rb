# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyReactor::Map::Dispatcher do
  let(:storage) { instance_double(RubyReactor::Storage::RedisAdapter) }
  # Mock as an object that responds to the method, avoiding class/instance confusion if config changes
  let(:async_router) { double("AsyncRouter") }

  before do
    allow(RubyReactor.configuration).to receive(:storage_adapter).and_return(storage)
    allow(RubyReactor.configuration).to receive(:async_router).and_return(async_router)
    allow(storage).to receive(:set_map_offset)
    allow(storage).to receive(:retrieve_map_offset).and_return(0)
    allow(async_router).to receive(:perform_map_element_async) # Allow call
  end

  describe ".perform" do
    let(:map_id) { "map_123" }
    let(:arguments) do
      {
        map_id: map_id,
        parent_reactor_class_name: "TestReactor",
        parent_context_id: "ctx_123",
        source: [1, 2, 3, 4, 5],
        batch_size: 2,
        step_name: "test_map",
        mapped_reactor_class: instance_double(Class, name: "MappedReactor")
      }
    end

    let(:parent_context) { instance_double(RubyReactor::Context, context_id: "ctx_123", reactor_class: double("ReactorClass", name: "TestReactor")) }

    before do
      allow(described_class).to receive(:load_parent_context_from_storage).and_return(parent_context)
      allow(described_class).to receive(:build_mapped_inputs).and_return({})
      allow(RubyReactor::ContextSerializer).to receive(:serialize_value).and_return("{}")

      # Allow steps access on reactor_class double for fallback logic
      steps_mock = { test_map: double(arguments: { argument_mappings: {} }) }
      allow(parent_context.reactor_class).to receive(:steps).and_return(steps_mock)
    end

    it "resolves source and dispatches the first batch" do
      # Expect 2 jobs queued (batch_size: 2)
      expect(async_router).to receive(:perform_map_element_async).twice

      # Expect offset to be updated to 2
      expect(storage).to receive(:set_map_offset).with(map_id, 2, "TestReactor")

      described_class.perform(arguments)
    end

    context "when continuation is true" do
      let(:arguments_with_continuation) { arguments.merge(continuation: true) }

      it "does not reset the offset" do
        expect(described_class).not_to receive(:initialize_map_metadata)
        # Should just proceed with dispatch
        expect(async_router).to receive(:perform_map_element_async).twice
        described_class.perform(arguments_with_continuation)
      end
    end

    context "when source is empty" do
      let(:arguments) { super().merge(source: []) }

      it "does nothing" do
        expect(async_router).not_to receive(:perform_map_element_async)
        described_class.perform(arguments)
      end
    end

    context "when resolved source is an Enumerable but not Array" do
      # Mocking user providing something like 1..10
      let(:arguments) { super().merge(source: (1..5)) }

      it "handles generic Enumerable source correctly via drop/take" do
        expect(async_router).to receive(:perform_map_element_async).twice
        described_class.perform(arguments)
      end
    end
  end
end
