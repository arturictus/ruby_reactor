# frozen_string_literal: true

module RubyReactor
  # MiddlewareRunner executes event hooks on a collection of configured middlewares.
  class MiddlewareRunner
    def initialize(middlewares)
      @middlewares = middlewares || []
    end

    # Dispatches the given lifecycle event to all configured middlewares.
    # Invokes the specific event hook method if defined, e.g., `on_start_reactor`.
    # Fallback to the generic `on` method if implemented on the middleware.
    # StandardErrors are swallowed and logged to prevent middleware failure from halting execution.
    def on(event, *args)
      @middlewares.each do |middleware|
        method_name = "on_#{event}"
        if middleware.respond_to?(method_name)
          middleware.send(method_name, *args)
        elsif middleware.respond_to?(:on)
          middleware.on(event, *args)
        end
      rescue StandardError => e
        RubyReactor.configuration.logger.warn(
          "RubyReactor middleware error in #{middleware.class} during #{event}: #{e.message}"
        )
      end
    end
  end
end
