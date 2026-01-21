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
    # Configure to use real Sidekiq execution (via TestSubject)
    # The helper handles async logic automatically if we don't force async: false
    subject = test_reactor(LoopTestReactor, { items: items })

    expect(subject).to be_success
    expect(subject.result).to be_a(RubyReactor::Success)

    # Since we are inline via TestSubject (which processes jobs), the jobs executed.

    # Verify results count
    context_id = subject.reactor_instance.context.context_id
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
  end
end
