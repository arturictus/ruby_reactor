# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyReactor::Step::MapStep do
  let(:context) do
    instance_double(RubyReactor::Context,
                    context_id: "test-context-id",
                    map_operations: {},
                    current_step: :test_step,
                    inline_async_execution: false,
                    intermediate_results: {},
                    composed_contexts: {},
                    reactor_class: double(name: "TestReactor"))
  end

  let(:storage_adapter) { instance_double(RubyReactor::Storage::RedisAdapter) }
  let(:async_router) { double("AsyncRouter") }

  before do
    allow(RubyReactor.configuration).to receive_messages(storage_adapter: storage_adapter, async_router: async_router)
    allow(async_router).to receive(:perform_map_element_async)
    allow(storage_adapter).to receive(:store_context)
    allow(storage_adapter).to receive(:set_map_counter)
    allow(storage_adapter).to receive(:initialize_map_operation)
    allow(storage_adapter).to receive(:set_last_queued_index)
    allow(storage_adapter).to receive(:retrieve_context).and_return({})
    allow(storage_adapter).to receive(:set_map_offset)
    allow(storage_adapter).to receive(:retrieve_map_offset).and_return(0)
    allow(context).to receive(:serialize_for_retry).and_return({})

    # Mock fallback lookup of steps in Dispatcher
    steps_mock = { test_step: double(arguments: { argument_mappings: {}, source: { source: [] } }) }
    allow(context.reactor_class).to receive(:steps).and_return(steps_mock)

    # Mock load_parent_context_from_storage to return our mocked context
    allow(RubyReactor::Map::Dispatcher).to receive(:load_parent_context_from_storage).and_return(context)
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

        expect(storage_adapter).to have_received(:set_map_counter).with(anything, 3, anything)
        expect(storage_adapter).to have_received(:initialize_map_operation).with(anything, 3, anything, anything)
      end
    end

    context "when source responds to size but not count (mimicking some AR relations or custom enumerables)" do
      let(:source) do
        # rubocop:disable RSpec/VerifiedDoubleReference
        instance_double("CustomEnumerable", size: 5).tap do |d|
          allow(d).to receive(:each_with_index)
          allow(d).to receive(:drop).and_return(d)
          allow(d).to receive(:take).and_return([])
        end
        # rubocop:enable RSpec/VerifiedDoubleReference
      end

      it "uses size successfully" do
        allow(described_class).to receive(:queue_map_element).and_return("job_id")
        allow(described_class).to receive(:queue_collector)

        described_class.send(:run_async, arguments, context, :test_step)

        expect(storage_adapter).to have_received(:set_map_counter).with(anything, 5, anything)
        expect(storage_adapter).to have_received(:initialize_map_operation).with(anything, 5, anything, anything)
      end
    end

    context "when source is an ActiveRecord::Relation mock" do
      let(:source) do
        # rubocop:disable RSpec/VerifiedDoubleReference
        instance_double("ActiveRecord::Relation", size: 10).tap do |d|
          allow(d).to receive(:each_with_index)
          allow(d).to receive(:count) # Allow it so we can spy on it
          allow(d).to receive(:drop).and_return(d)
          allow(d).to receive(:take).and_return([])
        end
        # rubocop:enable RSpec/VerifiedDoubleReference
      end

      it "calls size instead of count" do
        # Setup expectations as allowances for spies
        allow(source).to receive(:size).and_return(10)

        allow(described_class).to receive(:queue_map_element).and_return("job_id")
        allow(described_class).to receive(:queue_collector)

        described_class.send(:run_async, arguments, context, :test_step)

        expect(source).to have_received(:size).at_least(:once)
        expect(source).not_to have_received(:count)
        expect(storage_adapter).to have_received(:set_map_counter).with(anything, 10, anything)
      end
    end
  end
end
