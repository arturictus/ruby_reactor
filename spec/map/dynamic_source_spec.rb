# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Map with Dynamic Source" do
  let(:dynamic_source_reactor) do
    Class.new(RubyReactor::Reactor) do
      input :items
      input :factor

      map :processed_items do
        argument :raw_items, input(:items)
        argument :multiplier, input(:factor)

        source do |args, _context|
          # Dynamically create the source enumerable based on inputs
          args[:raw_items].map { |i| i * args[:multiplier] }
        end

        argument :item, element(:processed_items)

        step :transform do
          argument :val, input(:item)
          run { |args, _| RubyReactor::Success(args[:val] + 1) }
        end

        returns :transform
      end
    end
  end

  it "executes map with a dynamically generated source" do
    result = dynamic_source_reactor.run(items: [1, 2, 3], factor: 10)

    expect(result).to be_a(RubyReactor::Success)
    # Logic:
    # Source generation: items * 10 -> [10, 20, 30]
    # Map execution: item + 1 -> [11, 21, 31]
    expect(result.value[:processed_items]).to eq([11, 21, 31])
  end

  context "when dynamic source uses previous step results" do
    let(:chained_reactor) do
      Class.new(RubyReactor::Reactor) do
        input :start_range
        input :end_range

        step :generate_range do
          argument :start, input(:start_range)
          argument :finish, input(:end_range)
          run { |args, _| RubyReactor::Success((args[:start]..args[:finish]).to_a) }
        end

        map :doubled_range do
          argument :range, result(:generate_range)

          source do |args, _|
            # Filtering odd numbers only for the source
            args[:range].select(&:odd?)
          end

          argument :number, element(:doubled_range)

          step :double do
            argument :val, input(:number)
            run { |args, _| RubyReactor::Success(args[:val] * 2) }
          end

          returns :double
        end
      end
    end

    it "resolves source from previous step and transforms it" do
      result = chained_reactor.run(start_range: 1, end_range: 5)
      # Range: 1, 2, 3, 4, 5
      # Source (odds): 1, 3, 5
      # Map (double): 2, 6, 10

      expect(result).to be_a(RubyReactor::Success)
      expect(result.value[:doubled_range]).to eq([2, 6, 10])
    end
  end
end
