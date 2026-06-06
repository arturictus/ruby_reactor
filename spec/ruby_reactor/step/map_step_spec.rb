# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyReactor::Step::MapStep do
  let(:context) do
    # We need a closer-to-real context for real storage
    # But for unit testing the Step, we can still mock the context object itself if we serialize it?
    # Or should we use a real context too?
    # The user asked to not mock the STORAGE adapter.
    # The context is just an object passed around.
    # However, `load_parent_context_from_storage` is mocked below to return this context.
    # If we use real storage, we might need to store this context first.
    instance_double(RubyReactor::Context,
                    context_id: "test-context-id",
                    map_operations: {},
                    current_step: :test_step,
                    inline_async_execution: false,
                    intermediate_results: {},
                    composed_contexts: {},
                    middlewares: nil,
                    reactor_class: double(name: "TestReactor"))
  end

  let(:storage_adapter) { RubyReactor.configuration.storage_adapter }

  # Async router is fine to be mocked as we don't want to actually enqueue sidekiq jobs here unless necessary
  let(:async_router) { class_double(RubyReactor::SidekiqAdapter) }

  before do
    allow(RubyReactor.configuration).to receive(:async_router).and_return(async_router)
    allow(async_router).to receive(:perform_map_element_async)
    allow(async_router).to receive(:perform_map_collection_async)
    allow(async_router).to receive(:perform_map_execution_async)

    allow(context).to receive(:serialize_for_retry).and_return({
                                                                 context_id: "test-context-id",
                                                                 reactor_class: "TestReactor"
                                                               })

    # Allow stepping through map logic
    allow(context.reactor_class).to receive(:steps).and_return(
      { test_step: double(arguments: { argument_mappings: {}, source: { source: [] } }) }
    )

    # NOTE: We are using REAL storage adapter now, so no allows on storage_adapter.
    # But we might need to pre-seed data if the code expects it (e.g. load_parent_context_from_storage).

    # Store the parent context so Dispatcher can find it
    RubyReactor.configuration.storage_adapter.store_context(
      "test-context-id",
      JSON.dump({ context_id: "test-context-id", reactor_class: "TestReactor" }),
      "TestReactor"
    )
  end

  describe ".run_async" do
    let(:source) { [1, 2, 3] }
    let(:arguments) do
      {
        source: source,
        mapped_reactor_class: double(name: "MappedReactor"),
        argument_mappings: {},
        strict_ordering: true,
        batch_size: 2
      }
    end

    context "when source is an array" do
      it "uses size to count elements" do
        allow(described_class).to receive(:queue_map_element).and_return("job_id")
        allow(described_class).to receive(:queue_collector)

        described_class.send(:run_async, arguments, context, :test_step)

        # Verify side effects in Redis
        map_id = "test-context-id:test_step"
        metadata = storage_adapter.retrieve_map_metadata(map_id, "TestReactor")

        expect(metadata).not_to be_nil
        expect(metadata["count"].to_i).to eq(3)

        # Also verify counter
        # Depending on implementation, counter might be initialized separately
        # But metadata uses initialize_map_operation which sets it
      end
    end

    context "when source responds to size but not count (mimicking some AR relations or custom enumerables)" do
      let(:source) do
        # rubocop:disable RSpec/VerifiedDoubleReference
        instance_double("CustomEnumerable", size: 5).tap do |d|
          allow(d).to receive(:each_with_index)
          allow(d).to receive_messages(drop: d, take: [])
        end
        # rubocop:enable RSpec/VerifiedDoubleReference
      end

      it "uses size successfully" do
        allow(described_class).to receive(:queue_map_element).and_return("job_id")
        allow(described_class).to receive(:queue_collector)

        described_class.send(:run_async, arguments, context, :test_step)

        map_id = "test-context-id:test_step"
        metadata = storage_adapter.retrieve_map_metadata(map_id, "TestReactor")

        expect(metadata).not_to be_nil
        expect(metadata["count"].to_i).to eq(5)
      end
    end

    context "when source is an ActiveRecord::Relation mock" do
      let(:source) do
        # rubocop:disable RSpec/VerifiedDoubleReference
        instance_double("ActiveRecord::Relation", size: 10).tap do |d|
          allow(d).to receive(:each_with_index)
          allow(d).to receive(:count) # Allow it so we can spy on it
          allow(d).to receive_messages(drop: d, take: [])
        end
        # rubocop:enable RSpec/VerifiedDoubleReference
      end

      it "calls size instead of count and stores correct count" do
        # Setup expectations as allowances for spies
        allow(source).to receive(:size).and_return(10)

        allow(described_class).to receive(:queue_map_element).and_return("job_id")
        allow(described_class).to receive(:queue_collector)

        described_class.send(:run_async, arguments, context, :test_step)

        expect(source).to have_received(:size).at_least(:once)
        expect(source).not_to have_received(:count)

        map_id = "test-context-id:test_step"
        metadata = storage_adapter.retrieve_map_metadata(map_id, "TestReactor")
        expect(metadata["count"].to_i).to eq(10)
      end
    end
  end
end
