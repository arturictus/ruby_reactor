# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyReactor::Map::Dispatcher do
  let(:storage) { instance_double(RubyReactor::Storage::RedisAdapter) }
  let(:async_router) { class_double(RubyReactor::SidekiqAdapter) }

  before do
    allow(RubyReactor.configuration).to receive_messages(storage_adapter: storage, async_router: async_router)
    allow(storage).to receive(:set_map_offset_if_not_exists)
    allow(storage).to receive(:increment_map_offset).and_return(2) # First batch end offset
    allow(async_router).to receive(:perform_map_element_async)
  end

  describe ".perform" do
    let(:arguments) do
      {
        map_id: "map_123",
        parent_reactor_class_name: "TestReactor",
        parent_context_id: "ctx_123",
        source: [1, 2, 3, 4, 5],
        batch_size: 2,
        step_name: "test_map",
        mapped_reactor_class: instance_double(Class, name: "MappedReactor")
      }
    end

    let(:parent_context) do
      instance_double(RubyReactor::Context,
                      context_id: "ctx_123",
                      reactor_class: class_double(RubyReactor::Reactor, name: "TestReactor"))
    end

    before do
      allow(described_class).to receive_messages(load_parent_context_from_storage: parent_context,
                                                 build_mapped_inputs: {})
      allow(RubyReactor::ContextSerializer).to receive(:serialize_value).and_return("{}")
      allow(described_class).to receive(:initialize_map_metadata)

      # Allow steps access on reactor_class double for fallback logic
      steps_mock = { test_map: double(arguments: { argument_mappings: {} }) }
      allow(parent_context.reactor_class).to receive(:steps).and_return(steps_mock)
    end

    it "resolves source and dispatches the first batch" do
      described_class.perform(arguments)

      # Expect 2 jobs queued (batch_size: 2)
      expect(async_router).to have_received(:perform_map_element_async).twice
      # Expect offset to be incremented
      expect(storage).to have_received(:increment_map_offset).with("map_123", 2, "TestReactor")
    end

    context "when continuation is true" do
      let(:arguments) { super().merge(continuation: true) }

      it "does not reset the offset" do
        described_class.perform(arguments)

        expect(described_class).not_to have_received(:initialize_map_metadata)
        # Should just proceed with dispatch
        expect(async_router).to have_received(:perform_map_element_async).twice
      end
    end

    context "when source is empty" do
      let(:arguments) { super().merge(source: []) }

      it "does nothing" do
        described_class.perform(arguments)
        expect(async_router).not_to have_received(:perform_map_element_async)
      end
    end

    context "when resolved source is an Enumerable but not Array" do
      # Mocking user providing something like 1..10
      let(:arguments) { super().merge(source: (1..5)) }

      it "handles generic Enumerable source correctly via drop/take" do
        described_class.perform(arguments)
        expect(async_router).to have_received(:perform_map_element_async).twice
      end
    end

    context "when source responds to offset and limit (e.g. ActiveRecord::Relation)" do
      let(:relation) { instance_double("ActiveRecord::Relation") }
      let(:paginated_relation) { [1, 2] }
      let(:arguments) { super().merge(source: relation) }

      before do
        allow(relation).to receive(:offset).and_return(relation)
        allow(relation).to receive(:limit).and_return(relation)
        allow(relation).to receive(:to_a).and_return(paginated_relation)
      end

      it "uses offset and limit for efficiency" do
        described_class.perform(arguments)

        # Verify optimization is used
        expect(relation).to have_received(:offset).with(0) # First batch starts at 0
        expect(relation).to have_received(:limit).with(2)  # batch size
        expect(relation).to have_received(:to_a)

        expect(async_router).to have_received(:perform_map_element_async).twice
      end
    end
  end
end
