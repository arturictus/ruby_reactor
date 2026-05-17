# frozen_string_literal: true

# Define named class globally so persistence via name works
class InterruptUndoTestReactor < RubyReactor::Reactor
  def self.trace
    @trace ||= []
  end

  step :prepare do
    run do |_args, context|
      context.reactor_class.trace << :prepare_run
      Success("prep")
    end

    undo do |_result, _args, context|
      context.reactor_class.trace << :prepare_undo
      Success()
    end
  end

  interrupt :wait_for_input do
    wait_for :prepare

    validate do
      required(:status).filled(:string, eql?: "ok")
    end
  end

  step :process do
    argument :payload, result(:wait_for_input)

    run do |args, context|
      context.reactor_class.trace << :process_run
      Success(args[:payload])
    end
  end

  returns :process
end
