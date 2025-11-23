# frozen_string_literal: true

require "spec_helper"

class DoubleReactor < RubyReactor::Reactor
  input :number

  step :double do
    argument :number, input(:number)
    run { |args, _| RubyReactor::Success(args[:number] * 2) }
  end

  returns :double
end

class MapRootReactor < RubyReactor::Reactor
  input :numbers

  map :doubled_numbers, DoubleReactor do
    source input(:numbers)
    argument :number, element(:doubled_numbers)
  end
end

class InlineMapReactor < RubyReactor::Reactor
  input :numbers

  map :doubled_numbers do
    source input(:numbers)

    argument :number, element(:doubled_numbers)

    step :double do
      argument :val, input(:number)
      run { |args, _| RubyReactor::Success(args[:val] * 2) }
    end

    returns :double
  end
end

class CollectMapReactor < RubyReactor::Reactor
  input :numbers

  map :sum_doubles do
    source input(:numbers)

    argument :number, element(:sum_doubles)

    step :double do
      argument :val, input(:number)
      run { |args, _| RubyReactor::Success(args[:val] * 2) }
    end

    returns :double

    # rubocop:disable Style/SymbolProc
    collect do |results|
      # rubocop:enable Style/SymbolProc
      results.sum
    end
  end
end

RSpec.describe "Map Inline Execution" do
  it "executes map with class-based reactor" do
    result = MapRootReactor.run(numbers: [1, 2, 3])

    expect(result).to be_a(RubyReactor::Success)
    expect(result.value[:doubled_numbers]).to eq([2, 4, 6])
  end

  it "executes map with inline reactor definition" do
    result = InlineMapReactor.run(numbers: [1, 2, 3])

    expect(result).to be_a(RubyReactor::Success)
    expect(result.value[:doubled_numbers]).to eq([2, 4, 6])
  end

  it "executes map with collect transformation" do
    result = CollectMapReactor.run(numbers: [1, 2, 3])

    expect(result).to be_a(RubyReactor::Success)
    expect(result.value[:sum_doubles]).to eq(12) # (2+4+6)
  end

  it "handles empty source" do
    result = MapRootReactor.run(numbers: [])

    expect(result).to be_a(RubyReactor::Success)
    expect(result.value[:doubled_numbers]).to eq([])
  end
end
