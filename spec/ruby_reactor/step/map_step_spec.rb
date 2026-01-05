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
  let(:async_router) { instance_double(RubyReactor::AsyncRouter) }

  before do
    allow(RubyReactor.configuration).to receive_messages(storage_adapter: storage_adapter, async_router: async_router)
    allow(storage_adapter).to receive(:store_context)
    allow(storage_adapter).to receive(:set_map_counter)
    allow(storage_adapter).to receive(:initialize_map_operation)
    allow(storage_adapter).to receive(:set_last_queued_index)
    allow(context).to receive(:serialize_for_retry).and_return({})
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
        expect(storage_adapter).to receive(:set_map_counter).with(anything, 3, anything)
        expect(storage_adapter).to receive(:initialize_map_operation).with(anything, 3, anything, anything)

        # Stub fan out methods
        allow(described_class).to receive(:queue_map_element).and_return("job_id")
        allow(described_class).to receive(:queue_collector)

        described_class.send(:run_async, arguments, context, :test_step)
      end
    end

    context "when source responds to size but not count (mimicking some AR relations or custom enumerables)" do
      let(:source) do
        double("CustomEnumerable", size: 5).tap do |d|
          allow(d).to receive(:each_with_index)
        end
      end

      it "uses size successfully" do
        expect(storage_adapter).to receive(:set_map_counter).with(anything, 5, anything)
        expect(storage_adapter).to receive(:initialize_map_operation).with(anything, 5, anything, anything)

        allow(described_class).to receive(:queue_map_element).and_return("job_id")
        allow(described_class).to receive(:queue_collector)

        described_class.send(:run_async, arguments, context, :test_step)
      end
    end

    context "when source is an ActiveRecord::Relation mock" do
      let(:source) do
        double("ActiveRecord::Relation", size: 10).tap do |d|
          allow(d).to receive(:each_with_index)
        end
      end

      it "calls size instead of count" do
        expect(source).to receive(:size).at_least(:once).and_return(10)
        expect(source).not_to receive(:count) # Ensure count is NOT called

        expect(storage_adapter).to receive(:set_map_counter).with(anything, 10, anything)

        allow(described_class).to receive(:queue_map_element).and_return("job_id")
        allow(described_class).to receive(:queue_collector)

        described_class.send(:run_async, arguments, context, :test_step)
      end
    end
  end
end
