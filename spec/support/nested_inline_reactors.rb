# frozen_string_literal: true

module Support
  class NestedInlineChildReactor < RubyReactor::Reactor
    input :id

    step :async_step do
      run { |args, _| RubyReactor::Success("async_done_#{args.id}") }
    end

    background before: :async_step
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

    compose :child1, NestedInlineChildReactor do
      argument :id, value("child1")
    end

    compose :child2 do
      input :id

      step :async_step do
        run do |args, _|
          RubyReactor::Success("async_done_#{args.id}")
        end
      end

      step :other_step do
        run { |_, _| RubyReactor::Success("other_done") }
      end

      background before: :async_step

      argument :id, value("child2")
    end

    step :last_step do
      run { |_, _| RubyReactor::Success("last_step_done") }
    end
  end
end

module Support
  # Parent whose child is dispatched, not composed. Under `run_async(false)`
  # the child runs inline — and its OWN background hand-off has to be
  # suppressed too, or the child is left parked at "running".
  class AsyncReactorRootReactor < RubyReactor::Reactor
    input :id

    step :prepare do
      run { |_, _| RubyReactor::Success("prepared") }
    end

    async_reactor :child_job, NestedInlineChildReactor do
      argument :id, input(:id)
    end
  end
end
