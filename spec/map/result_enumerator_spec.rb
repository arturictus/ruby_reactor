# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyReactor::Map::ResultEnumerator do
  let(:storage) { instance_double(RubyReactor::Storage::RedisAdapter) }
  let(:map_id) { "map_123" }
  let(:reactor_class_name) { "TestReactor" }
  let(:enumerator) { described_class.new(map_id, reactor_class_name, batch_size: 2) }

  before do
    allow(RubyReactor.configuration).to receive(:storage_adapter).and_return(storage)
  end

  describe "#each" do
    it "yields results in batches" do
      # Mocking 2 batches of results
      batch1 = %w[result1 result2]
      batch2 = ["result3"]

      expect(storage).to receive(:retrieve_map_results_batch)
        .with(map_id, reactor_class_name, offset: 0, limit: 2, strict_ordering: true)
        .and_return(batch1)

      expect(storage).to receive(:retrieve_map_results_batch)
        .with(map_id, reactor_class_name, offset: 2, limit: 2, strict_ordering: true)
        .and_return(batch2)

      results = enumerator.to_a
      expect(results.map(&:value)).to eq(%w[result1 result2 result3])
      expect(results.all? { |r| r.is_a?(RubyReactor::Success) }).to be true
    end

    it "stops when results are empty" do
      expect(storage).to receive(:retrieve_map_results_batch)
        .with(map_id, reactor_class_name, offset: 0, limit: 2, strict_ordering: true)
        .and_return([])

      expect(enumerator.to_a).to be_empty
    end
  end
end
