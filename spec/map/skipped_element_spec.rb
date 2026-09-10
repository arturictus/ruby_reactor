# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Map element returning Skipped" do
  class SkippedElementReactor < RubyReactor::Reactor
    input :items

    map :processed do
      source input(:items)
      argument :item, element(:processed)

      step :process do
        argument :val, input(:item)
        run do |args, _|
          if args[:val] == "skip_me"
            RubyReactor::Skipped("was_skipped")
          else
            RubyReactor::Success(args[:val].upcase)
          end
        end
      end

      returns :process
    end
  end

  it "continues past a skipped element and collects its value like any other" do
    result = SkippedElementReactor.run(items: %w[hello skip_me world])

    expect(result).to be_a(RubyReactor::Success)
    expect(result.value[:processed]).to eq(%w[HELLO was_skipped WORLD])
  end
end
