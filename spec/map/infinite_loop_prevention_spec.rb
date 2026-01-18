# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Map Infinite Loop Prevention" do
  class LoopTestReactor < RubyReactor::Reactor
    input :items

    map :process_items do
      source input(:items)
      argument :item, element(:process_items)

      async true, batch_size: 2

      step :record do
        argument :item, input(:item)
        run do |args|
          Success(args[:item])
        end
      end

      returns :record
    end
  end

  let(:items) { (1..10).to_a }
  let(:storage) { RubyReactor::Configuration.instance.storage_adapter }

  it "processes all items exactly once without looping" do
    # Configure to use real Sidekiq execution (inline)
    original_router = RubyReactor.configuration.async_router
    RubyReactor.configure { |c| c.async_router = RubyReactor::SidekiqAdapter }
    Sidekiq::Testing.inline!

    begin
      executor = RubyReactor::Executor.new(LoopTestReactor, items: items)
      result = executor.execute
      context_id = executor.context.context_id

      expect(result).to be_a(RubyReactor::Success)

      # Since we are inline, the jobs executed immediately.
      # The Executor now correctly detects this completion via the reload mechanism in StepExecutor.

      # Verify results count
      # The map results are stored under the MAP context ID, which is derived from parent context + step name
      # Map ID: "#{context_id}:process_items"
      map_id = "#{context_id}:process_items"

      results = storage.retrieve_map_results(map_id, "LoopTestReactor", strict_ordering: true)

      expect(results.size).to eq(10)
      expect(results.sort).to eq(items)

      # Extra verification: Check offset in Redis
      offset_key = "reactor:LoopTestReactor:map:#{map_id}:offset"
      redis_url = RubyReactor.configuration.storage.redis_url
      final_offset = Redis.new(url: redis_url).get(offset_key).to_i

      # It should be at least 10.
      expect(final_offset).to be >= 10
    ensure
      # Restore
      RubyReactor.configure { |c| c.async_router = original_router }
      Sidekiq::Testing.fake!
    end
  end
end
