# frozen_string_literal: true

module Support
  class MapMockTestReactor < RubyReactor::Reactor
    input :list

    map :process_list do
      source input(:list)
      argument :value, element(:process_list)

      step :transform do
        argument :value, input(:value)
        run { |args| RubyReactor::Success(args[:value] * 2) }
      end
    end

    map :label_list do
      source input(:list)
      argument :value, element(:label_list)

      step :label do
        argument :value, input(:value)
        run { |args| RubyReactor::Success("item_#{args[:value]}") }
      end
    end
  end

  # Same shape, but every element runs as its own background job.
  class FanOutMapMockTestReactor < RubyReactor::Reactor
    input :list

    map :process_list do
      source input(:list)
      argument :value, element(:process_list)
      fan_out

      step :transform do
        argument :value, input(:value)
        run { |args| RubyReactor::Success(args[:value] * 2) }
      end
    end
  end
end
