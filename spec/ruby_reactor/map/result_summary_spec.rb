# frozen_string_literal: true

require "spec_helper"

# The dashboard used to inline a map's whole result set, which materialized the
# lazy enumerator inside the JSON encoder and buried the element failures.
RSpec.describe "map result summarization for the API" do
  subject(:summary) { RubyReactor::ContextSerializer.simplify_for_api(enumerator) }

  let(:storage) { instance_double(RubyReactor::Storage::RedisAdapter) }
  let(:failure) do
    RubyReactor::Failure.new(
      "boom",
      step_name: "randomly_fail",
      exception_class: "RuntimeError",
      backtrace: (1..30).map { |i| "app/reactors/x.rb:#{i}" }
    )
  end
  let(:results) do
    [
      { "value" => 1 },
      { "_error" => RubyReactor::ContextSerializer.serialize_value(failure) },
      { "value" => 3 }
    ]
  end
  let(:enumerator) { RubyReactor::Map::ResultEnumerator.new("map_1", "ParentReactor") }

  before do
    allow(RubyReactor.configuration).to receive(:storage_adapter).and_return(storage)
    allow(storage).to receive(:count_map_results).and_return(results.size)
    allow(storage).to receive(:retrieve_map_results_batch)
      .with("map_1", "ParentReactor", offset: 0, limit: results.size)
      .and_return(results)
  end

  it "counts elements instead of inlining them" do
    expect(summary).to include(
      "_type" => "map_results", "total" => 3, "succeeded" => 2, "failed" => 1,
      "failures_truncated" => false
    )
  end

  it "keeps each failure's own step and exception" do
    expect(summary["failures"].first).to include(
      "error" => "boom", "step_name" => "randomly_fail",
      "exception_class" => "RuntimeError", "index" => 1
    )
  end

  it "caps the sampled backtrace" do
    expect(summary["failures"].first["backtrace"].size)
      .to eq(RubyReactor::Map::ResultSummary::BACKTRACE_FRAMES)
  end

  it "samples at most SAMPLE_LIMIT failures" do
    limit = RubyReactor::Map::ResultSummary::SAMPLE_LIMIT
    many = Array.new(limit + 5) { { "_error" => "boom" } }
    allow(storage).to receive(:count_map_results).and_return(many.size)
    allow(storage).to receive(:retrieve_map_results_batch)
      .with("map_1", "ParentReactor", offset: 0, limit: many.size).and_return(many)

    expect(summary).to include("failed" => limit + 5, "failures_truncated" => true)
    expect(summary["failures"].size).to eq(limit)
  end

  it "omits indices while the map is still filling in, since gaps shift positions" do
    allow(storage).to receive(:count_map_results).and_return(10)
    allow(storage).to receive(:retrieve_map_results_batch)
      .with("map_1", "ParentReactor", offset: 0, limit: 10).and_return(results)

    expect(summary["failures"].first).not_to have_key("index")
  end

  # Without an explicit empty backtrace, Failure falls back to `caller`, so a
  # bare-message element failure reported whoever happened to read the
  # enumerator — for the dashboard, the JSON encoder's own stack.
  it "does not attribute the reader's stack to a bare-message failure" do
    allow(storage).to receive(:count_map_results).and_return(1)
    allow(storage).to receive(:retrieve_map_results_batch)
      .with("map_1", "ParentReactor", offset: 0, limit: 1, strict_ordering: true)
      .and_return([{ "_error" => "boom" }])

    expect(enumerator.first.backtrace).to be_empty
  end
end
