# frozen_string_literal: true

module Support
  class NestedInlineChildReactor < RubyReactor::Reactor
    input :id

    step :async_step do
      async true
      run { |args, _| RubyReactor::Success("async_done_#{args[:id]}") }
    end
  end

  class NestedInlineRootReactor < RubyReactor::Reactor
    input :id

    step :prepare do
      run { |_, _| RubyReactor::Success("prepared") }
    end

    compose :child_process, NestedInlineChildReactor do
      argument :id, input(:id)
    end
  end
end
