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
  end
end
