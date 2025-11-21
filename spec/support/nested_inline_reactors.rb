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

  class MultipleComposeRootReactor < RubyReactor::Reactor
    input :id

    step :first_step do
      run { |_, _| RubyReactor::Success("first_step_done") }
    end

    compose :child_1, NestedInlineChildReactor do
      argument :id, value("child_1")
    end

    compose :child_2 do
      input :id

      step :async_step do
        async true
        run { |args, _| RubyReactor::Success("async_done_#{args[:id]}") }
      end

      argument :id, value("child_2")
    end

    step :last_step do
      run { |_, _| RubyReactor::Success("last_step_done") }
    end
  end
end
