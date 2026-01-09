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

  describe "#successes" do
    it "filters only successful results" do
      batch = ["success1", { "_error" => "failed1" }, "success2"]

      expect(storage).to receive(:retrieve_map_results_batch)
        .with(map_id, reactor_class_name, offset: 0, limit: 2, strict_ordering: true)
        .and_return(batch.first(2))
      expect(storage).to receive(:retrieve_map_results_batch)
        .with(map_id, reactor_class_name, offset: 2, limit: 2, strict_ordering: true)
        .and_return([batch.last])

      successes = enumerator.successes.to_a
      expect(successes.size).to eq(2)
      expect(successes.all? { |r| r.is_a?(RubyReactor::Success) }).to be true
      expect(successes.map(&:value)).to eq(%w[success1 success2])
    end
  end

  describe "#failures" do
    it "filters only failed results" do
      batch = ["success1", { "_error" => "failed1" }, { "_error" => "failed2" }]

      expect(storage).to receive(:retrieve_map_results_batch)
        .with(map_id, reactor_class_name, offset: 0, limit: 2, strict_ordering: true)
        .and_return(batch.first(2))
      expect(storage).to receive(:retrieve_map_results_batch)
        .with(map_id, reactor_class_name, offset: 2, limit: 2, strict_ordering: true)
        .and_return([batch.last])

      failures = enumerator.failures.to_a
      expect(failures.size).to eq(2)
      expect(failures.all? { |r| r.is_a?(RubyReactor::Failure) }).to be true
      expect(failures.map(&:error)).to eq(%w[failed1 failed2])
    end
  end
end
