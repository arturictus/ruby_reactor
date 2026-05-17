require "rails_helper"

RSpec.describe MapDemoReactor, type: :reactor do
  let(:inline_list) { [1, 2, 3] }
  let(:async_list)  { [4, 5] }
  let(:batch_list)  { (1..6).to_a }

  before do
    3.times { |i| Product.find_or_create_by!(name: "MapProduct #{i}", stock: 5 + i) }
  end

  # ar_query is passed-through as an input and gets serialized by the
  # storage adapter, so an ActiveRecord::Relation cannot survive the round
  # trip here (see ar_map_reactor_spec.rb for the `source do …end` pattern
  # that does work). Use an empty array to exercise the rest of the maps.
  let(:inputs) do
    {
      inline_list: inline_list,
      async_list:  async_list,
      batch_list:  batch_list,
      ar_query:    []
    }
  end

  subject(:reactor) { test_reactor(described_class, inputs) }

  it "executes inline, async, batched, and AR-backed maps successfully" do
    expect(reactor).to be_success
  end

  it "produces the expected inline_map results" do
    expect(reactor).to have_run_step(:inline_map)
    # double then increment: [1,2,3] -> [3,5,7]
    expect(reactor.step_result(:inline_map)).to match_array([3, 5, 7])
  end

  it "produces stringified async_map results" do
    expect(reactor.step_result(:async_map)).to match_array(["Result: 16", "Result: 25"])
  end

  context "when an inner step fails inside inline_map" do
    let(:inputs) do
      super().merge(fail_at_reactor: :inline_map, fail_at_step: :double)
    end

    it "fails the parent reactor" do
      expect(reactor).to be_failure
    end
  end
end
