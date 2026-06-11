# frozen_string_literal: true

require "spec_helper"

class MiddlewareTestStep
  def self.run(arguments, _context)
    raise "step failed" if arguments[:should_fail]

    RubyReactor.Success(arguments[:value].to_i * 2)
  end
end

class MiddlewareExecutionTracker
  class << self
    attr_accessor :events

    def reset
      @events = []
    end
  end
end

class TestGlobalMiddleware < RubyReactor::Middleware
  def on_start_reactor(reactor_name, inputs, _context)
    MiddlewareExecutionTracker.events << { type: :global_start_reactor, name: reactor_name, inputs: inputs }
  end

  def on_complete_reactor(reactor_name, result, _context)
    MiddlewareExecutionTracker.events << { type: :global_complete_reactor, name: reactor_name,
                                           success: result.success? }
  end
end

class TestLocalMiddleware < RubyReactor::Middleware
  def on_start_reactor(reactor_name, _inputs, _context)
    MiddlewareExecutionTracker.events << { type: :local_start_reactor, name: reactor_name, opt: options[:opt] }
  end

  def on_start_step(step_name, _arguments, _context)
    MiddlewareExecutionTracker.events << { type: :local_start_step, name: step_name }
  end
end

class FallbackMiddleware < RubyReactor::Middleware
  def on(event, *args)
    MiddlewareExecutionTracker.events << { type: :fallback, event: event, args_count: args.size }
  end
end

class ErrorRaisingMiddleware < RubyReactor::Middleware
  def on_start_reactor(_reactor_name, _inputs, _context)
    raise "middleware crash!"
  end
end

class TestMiddlewareReactor < RubyReactor::Reactor
  input :input_val
  input :should_fail, optional: true

  middleware TestLocalMiddleware, opt: "local_opt"
  middleware FallbackMiddleware

  step :double_it, MiddlewareTestStep do
    argument :value, input(:input_val)
    argument :should_fail, input(:should_fail)
  end

  returns :double_it
end

RSpec.describe "RubyReactor Middleware System" do
  before do
    MiddlewareExecutionTracker.reset
    RubyReactor.configure do |config|
      config.middlewares = [TestGlobalMiddleware]
    end
  end

  after do
    RubyReactor.configure do |config|
      config.middlewares = []
    end
  end

  describe "Middleware Resolution & Merge Order" do
    it "resolves and executes global and local middlewares in correct order" do
      result = TestMiddlewareReactor.run(input_val: 10)
      expect(result).to be_success
      expect(result.value).to eq(20)

      events = MiddlewareExecutionTracker.events

      # Merge order: Global first, then local (TestLocalMiddleware), then FallbackMiddleware
      expect(events[0]).to eq({ type: :global_start_reactor, name: "TestMiddlewareReactor", inputs: { input_val: 10 } })
      expect(events[1]).to eq({ type: :local_start_reactor, name: "TestMiddlewareReactor", opt: "local_opt" })

      # FallbackMiddleware on_start_reactor caught by generic `on` method
      fallback_start_reactor = events.find { |e| e[:type] == :fallback && e[:event] == :start_reactor }
      expect(fallback_start_reactor).not_to be_nil
      expect(fallback_start_reactor[:args_count]).to eq(3)

      # Step hooks
      expect(events).to include({ type: :local_start_step, name: :double_it })

      # Reactor completion
      expect(events).to include({ type: :global_complete_reactor, name: "TestMiddlewareReactor", success: true })
    end

    it "supports configuring instantiated middlewares as well as classes" do
      instantiated = TestLocalMiddleware.new(opt: "instantiated_opt")

      RubyReactor.configure do |config|
        config.middlewares = [instantiated]
      end

      # Run a reactor that has no local middlewares
      reactor_class = Class.new(RubyReactor::Reactor) do
        step :dummy do
          run { RubyReactor.Success("ok") }
        end
      end

      reactor_class.run

      events = MiddlewareExecutionTracker.events
      start_event = events.find { |e| e[:type] == :local_start_reactor }
      expect(start_event).not_to be_nil
      expect(start_event[:opt]).to eq("instantiated_opt")
    end
  end

  describe "Error Safety" do
    it "swallows middleware errors and does not crash the reactor execution" do
      RubyReactor.configure do |config|
        config.middlewares = [ErrorRaisingMiddleware]
      end

      # Expect the reactor to run successfully even if the middleware raises StandardError
      result = TestMiddlewareReactor.run(input_val: 5)
      expect(result).to be_success
      expect(result.value).to eq(10)
    end
  end
end
