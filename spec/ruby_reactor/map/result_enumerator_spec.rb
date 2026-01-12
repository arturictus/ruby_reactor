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

  describe "#count" do
    it "returns the count from storage" do
      allow(storage).to receive(:count_map_results)
        .with(map_id, reactor_class_name)
        .and_return(5)

      expect(enumerator.count).to eq(5)
    end
  end

  describe "#empty?" do
    it "returns true if count is 0" do
      allow(storage).to receive(:count_map_results).and_return(0)
      expect(enumerator.empty?).to be true
    end

    it "returns false if count is > 0" do
      allow(storage).to receive(:count_map_results).and_return(1)
      expect(enumerator.empty?).to be false
    end
  end

  describe "#any?" do
    it "returns false if count is 0" do
      allow(storage).to receive(:count_map_results).and_return(0)
      expect(enumerator.any?).to be false
    end

    it "returns true if count is > 0" do
      allow(storage).to receive(:count_map_results).and_return(1)
      expect(enumerator.any?).to be true
    end
  end

  describe "#[]" do
    it "retrieves specific item by index" do
      allow(storage).to receive(:count_map_results).and_return(5)
      allow(storage).to receive(:retrieve_map_results_batch)
        .with(map_id, reactor_class_name, offset: 2, limit: 1, strict_ordering: true)
        .and_return(["result3"])

      result = enumerator[2]
      expect(result).to be_a(RubyReactor::Success)
      expect(result.value).to eq("result3")
    end

    it "returns nil if index out of bounds" do
      allow(storage).to receive(:count_map_results).and_return(5)
      expect(enumerator[10]).to be_nil
    end
  end

  describe "#first" do
    it "returns the first item" do
      allow(storage).to receive(:count_map_results).and_return(5)
      allow(storage).to receive(:retrieve_map_results_batch)
        .with(map_id, reactor_class_name, offset: 0, limit: 1, strict_ordering: true)
        .and_return(["result1"])

      expect(enumerator.first.value).to eq("result1")
    end
  end

  describe "#last" do
    it "returns the last item" do
      allow(storage).to receive(:count_map_results).and_return(5)
      allow(storage).to receive(:retrieve_map_results_batch)
        .with(map_id, reactor_class_name, offset: 4, limit: 1, strict_ordering: true)
        .and_return(["result5"])

      expect(enumerator.last.value).to eq("result5")
    end
  end

  describe "#each" do
    it "yields results one by one using index access for strict ordering" do
      allow(storage).to receive(:count_map_results).and_return(3)

      allow(storage).to receive(:retrieve_map_results_batch)
        .with(map_id, reactor_class_name, offset: 0, limit: 1, strict_ordering: true)
        .and_return(["result1"])
      allow(storage).to receive(:retrieve_map_results_batch)
        .with(map_id, reactor_class_name, offset: 1, limit: 1, strict_ordering: true)
        .and_return(["result2"])
      allow(storage).to receive(:retrieve_map_results_batch)
        .with(map_id, reactor_class_name, offset: 2, limit: 1, strict_ordering: true)
        .and_return(["result3"])

      results = enumerator.to_a
      expect(results.map(&:value)).to eq(%w[result1 result2 result3])
    end

    context "with strict_ordering: false" do
      let(:enumerator) { described_class.new(map_id, reactor_class_name, strict_ordering: false, batch_size: 2) }

      it "yields results in batches" do
        batch1 = %w[result1 result2]
        batch2 = ["result3"]

        allow(storage).to receive(:retrieve_map_results_batch)
          .with(map_id, reactor_class_name, offset: 0, limit: 2, strict_ordering: false)
          .and_return(batch1)

        allow(storage).to receive(:retrieve_map_results_batch)
          .with(map_id, reactor_class_name, offset: 2, limit: 2, strict_ordering: false)
          .and_return(batch2)

        results = enumerator.to_a
        expect(results.map(&:value)).to eq(%w[result1 result2 result3])
      end
    end
  end

  describe "#successes" do
    it "filters only successful results" do
      allow(storage).to receive(:count_map_results).and_return(3)
      allow(storage).to receive(:retrieve_map_results_batch).and_return(["success1"], [{ "_error" => "failed1" }],
                                                                        ["success2"])

      successes = enumerator.successes.to_a
      expect(successes).to eq(%w[success1 success2])
    end
  end

  describe "#failures" do
    it "filters only failed results" do
      allow(storage).to receive(:count_map_results).and_return(3)
      allow(storage).to receive(:retrieve_map_results_batch).and_return(["success1"], [{ "_error" => "failed1" }],
                                                                        [{ "_error" => "failed2" }])

      failures = enumerator.failures.to_a
      expect(failures).to eq(%w[failed1 failed2])
    end
  end
end
