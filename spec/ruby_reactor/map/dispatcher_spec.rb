# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyReactor::Map::Dispatcher do
  let(:storage) { instance_double(RubyReactor::Storage::RedisAdapter) }
  let(:async_router) { class_double(RubyReactor::Adapters::Sidekiq::Router) }

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
                      middlewares: nil,
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
      # rubocop:disable RSpec/VerifiedDoubles
      let(:relation) { double("ActiveRecord::Relation") }
      # rubocop:enable RSpec/VerifiedDoubles

      let(:arguments) { super().merge(source: relation) }

      before do
        # rubocop:disable RSpec/ReceiveMessages
        allow(relation).to receive(:offset).and_return(relation)
        allow(relation).to receive(:limit).and_return(relation)
        allow(relation).to receive(:to_a).and_return([1, 2])
        # rubocop:enable RSpec/ReceiveMessages

        # Dispatcher checks resolve on source
        allow(relation).to receive(:respond_to?).with(:resolve).and_return(false)
        # Dispatcher checks for optimization
        allow(relation).to receive(:respond_to?).with(:offset).and_return(true)
        allow(relation).to receive(:respond_to?).with(:limit).and_return(true)
      end

      it "uses offset and limit for efficiency" do
        described_class.perform(arguments)

        expect(relation).to have_received(:offset).with(0)
        expect(relation).to have_received(:limit).with(2)

        expect(async_router).to have_received(:perform_map_element_async).twice
      end
    end
  end

  # 009 R-02, R-06: one throw of a distributed map rollback.
  describe ".dispatch_rollback_batch" do
    let(:storage) { RubyReactor::Storage::RedisAdapter.new(url: REDIS_TEST_URL) }
    let(:jobs) { [] }

    before do
      allow(async_router).to receive(:perform_map_element_rollback_async) { |**args| jobs << args }
      %w[a b c d e].each { |id| storage.store_map_element_context_id("p:m", id, "P") }
      storage.start_map_rollback("p:m", "P", total: 5, batch_size: 2, step_name: "m", owner_context_id: "p",
                                             owner_reactor_class_name: "P", reactor_class_info: { "type" => "class" })
    end

    it "claims at most batch_size positions, newest first, and none past the total" do
      3.times { described_class.dispatch_rollback_batch(map_id: "p:m", parent_reactor_class_name: "P") }
      expect(described_class.dispatch_rollback_batch(map_id: "p:m", parent_reactor_class_name: "P")).to eq(0)

      expect(jobs.map { |job| [job[:position], job[:element_context_id]] })
        .to eq([[0, "e"], [1, "d"], [2, "c"], [3, "b"], [4, "a"]])
      expect(jobs.first).to include(map_id: "p:m", batch_size: 2, owner_context_id: "p", attempt: 0)
    end
  end
end
