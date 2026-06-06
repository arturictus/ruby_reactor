# frozen_string_literal: true

module RubyReactor
  # Base class for all middlewares in RubyReactor.
  # Middlewares allow hooking into the execution lifecycle of reactors and steps.
  class Middleware
    attr_reader :options

    def initialize(**options)
      @options = options
    end
  end
end
