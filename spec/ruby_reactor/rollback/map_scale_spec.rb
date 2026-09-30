# frozen_string_literal: true

require "spec_helper"

# SC-006: a large map fails and rolls every element back without growing the
# parent's stored state per element. Slow: `bundle exec rspec --tag slow`.
module MapScaleSpec
  class Elem < RubyReactor::Reactor
    def self.undone
      @undone ||= []
    end

    input :i

    step :touch do
      argument :i, input(:i)
      run { |inputs, _ctx| RubyReactor.Success(inputs.i) }
      undo do |_value, inputs, _ctx|
        MapScaleSpec::Elem.undone << inputs.i
        RubyReactor.Success()
      end
    end
  end

  COLLECT_RAISES = ->(_results) { raise "collect exploded" }

  # The source is a Range, which serializes at constant size, so the parent's
  # size can only grow with the element count through the map itself.
  class CollectRaises < RubyReactor::Reactor
    input :count

    step :ids do
      argument :count, input(:count)
      run { |inputs, _ctx| RubyReactor.Success(0...inputs.count) }
    end

    map :m, Elem do
      source result(:ids)
      argument :i, element(:m)
      collect(&COLLECT_RAISES)
    end
  end
end

RSpec.describe "map rollback at scale", :slow do
  let(:storage) { RubyReactor.configuration.storage_adapter }

  def run_and_measure(size)
    MapScaleSpec::Elem.undone.clear
    reactor = MapScaleSpec::CollectRaises.new
    result = reactor.run(count: size)
    parent = storage.retrieve_context(reactor.context.context_id, MapScaleSpec::CollectRaises.name)
    [result, JSON.generate(parent).bytesize]
  end

  it "undoes all 10,000 elements with parent state about the size of a 10-element map" do
    _small, small_size = run_and_measure(10)
    result, large_size = run_and_measure(10_000)

    expect(result).to be_failure
    expect(MapScaleSpec::Elem.undone.size).to eq(10_000)
    expect(MapScaleSpec::Elem.undone.first).to eq(9_999)
    expect(large_size).to be <= small_size * 2
  end
end
