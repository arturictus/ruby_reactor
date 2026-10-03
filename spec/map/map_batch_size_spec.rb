# frozen_string_literal: true

require "spec_helper"

module MapDefaultBatchSizeSpec
  MapRollbackFixtures.parent(self, :Unbatched, MapRollbackFixtures::ElemOk, fan_out: true)
  MapRollbackFixtures.parent(self, :Batched200, MapRollbackFixtures::ElemOk, fan_out: true, batch_size: 200)
  MapRollbackFixtures.parent(self, :UnbatchedFails, MapRollbackFixtures::ElemOk, fan_out: true, b_fails: true)
end

# 009 US3, FR-017–FR-019, SC-004: `fan_out` without `batch_size` enqueues at
# most 50 element jobs per throw, forward and rollback. The bound is per
# throw (FR-002, R-02); queue depth is not asserted.

RSpec.describe "Map Batch Size Execution" do
  before do
    # Use real Redis from spec_helper configuration
    # But we need to ensure Adapters::Sidekiq::Router is used instead of WorkerMock for this test
    allow(RubyReactor.configuration).to receive(:async_router).and_return(RubyReactor::Adapters::Sidekiq::Router)

    Sidekiq::Testing.fake!
  end

  after do
    Sidekiq::Testing.inline!
  end

  it "queues only batch_size elements initially and queues more as they finish" do
    # 10 elements
    numbers = (1..10).to_a
    result = MapTestReactors::BatchMapReactor.run(numbers: numbers)

    expect(result).to be_a(RubyReactor::DispatchResult)

    # Should only queue 2 jobs initially because batch_size is 2
    expect(RubyReactor::Adapters::Sidekiq::MapElementWorker.jobs.size).to eq(2)

    # Process the first batch
    initial_jobs = RubyReactor::Adapters::Sidekiq::MapElementWorker.jobs.dup
    RubyReactor::Adapters::Sidekiq::MapElementWorker.clear

    initial_jobs.each do |job|
      RubyReactor::Adapters::Sidekiq::MapElementWorker.new.perform(*job["args"])
    end

    # Should have queued 2 more jobs (indices 2 and 3)
    expect(RubyReactor::Adapters::Sidekiq::MapElementWorker.jobs.size).to eq(2)

    # Verify the indices
    job_args = RubyReactor::Adapters::Sidekiq::MapElementWorker.jobs.map { |j| j["args"].first }
    indices = job_args.map { |a| a["index"] }
    expect(indices).to contain_exactly(2, 3)
  end

  describe "invalid batch_size" do
    def define_map_reactor(**fan_out_args)
      Class.new(RubyReactor::Reactor) do
        input :numbers

        map :doubled, MapTestReactors::DoubleReactor do
          source input(:numbers)
          argument :number, element(:doubled)
          fan_out(**fan_out_args)
        end
      end
    end

    it "rejects batch_size: 0 at definition time instead of stalling the map" do
      expect do
        define_map_reactor(batch_size: 0)
      end.to raise_error(RubyReactor::Error::ValidationError, /batch_size.*positive Integer/)
    end

    it "rejects a negative batch_size" do
      expect do
        define_map_reactor(batch_size: -1)
      end.to raise_error(RubyReactor::Error::ValidationError, /batch_size.*positive Integer/)
    end

    it "rejects a non-integer batch_size" do
      expect do
        define_map_reactor(batch_size: 1.5)
      end.to raise_error(RubyReactor::Error::ValidationError, /batch_size.*positive Integer/)
    end
  end

  describe "fan_out default batch size (009 US3)" do
    let(:storage) { RubyReactor.configuration.storage_adapter }

    def items(count) = { items: (0...count).to_a }

    for_each_async_backend do
      it "throws at most 50 element jobs for 500 elements, and collects all 500" do
        reactor = MapDefaultBatchSizeSpec::Unbatched
        id = reactor.run(items(500)).execution_id

        expect(QueueProbe.drain_tracking("MapElementWorker")[:max_burst]).to be <= 50
        expect(storage.count_map_results("#{id}:m", reactor.name)).to eq(500)
        expect(storage.retrieve_map_metadata("#{id}:m", reactor.name)["batch_size"]).to eq(50)
        expect(reactor.find(id).context.status.to_s).to eq("completed")
      end

      it "throws all 20 elements at once when there are fewer than 50" do
        MapDefaultBatchSizeSpec::Unbatched.run(items(20))

        expect(QueueProbe.enqueued("MapElementWorker")).to eq(20)
      end

      it "uses a declared batch_size instead of the default" do
        MapDefaultBatchSizeSpec::Batched200.run(items(500))

        expect(QueueProbe.drain_tracking("MapElementWorker")[:max_burst]).to eq(200)
      end

      it "rolls back with the same default" do
        reactor = MapDefaultBatchSizeSpec::UnbatchedFails
        id = reactor.run(items(120)).execution_id

        expect(QueueProbe.drain_tracking("MapElementRollbackWorker")[:max_burst]).to be <= 50
        expect(reactor.find(id).context.status.to_s).to eq("failed")
      end
    end
  end
end
