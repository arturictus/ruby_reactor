# frozen_string_literal: true

require "sidekiq"

module RubyReactor
  # Sidekiq worker for executing RubyReactor reactors asynchronously
  # with non-blocking retry capabilities
  class Worker
    include Sidekiq::Worker

    # Enable Sidekiq retries for infrastructure failures only
    sidekiq_options retry: RubyReactor.configuration.sidekiq_retry_count, dead: false,
                    queue: RubyReactor.configuration.sidekiq_queue

    sidekiq_retries_exhausted do |_, exception|
      # Handle infrastructure failures (network, Redis, etc.)
    end

    def perform(serialized_context, reactor_class_name = nil)
      context = ContextSerializer.deserialize(serialized_context)

      # If reactor_class_name is provided, use it to get the reactor class
      # This handles cases where the class can't be found via const_get
      if reactor_class_name && context.reactor_class.nil?
        begin
          context.reactor_class = Object.const_get(reactor_class_name)
        rescue NameError
          # If not found, try to find it in the current namespace
          # This is a fallback for test environments
          context.reactor_class = reactor_class_name.constantize if reactor_class_name.respond_to?(:constantize)
        end
      end

      # Mark that we're executing inline to prevent nested async calls
      context.inline_async_execution = true

      # Resume execution from the failed step
      executor = Executor.new(context.reactor_class, {}, context)
      executor.compensation_manager.undo_stack.concat(context.undo_stack)
      executor.resume_execution

      # Return the executor (which now has the result stored in it)
      executor
    end

    private

    def log_infrastructure_failure(msg, exception)
      Sidekiq.logger.error("RubyReactor infrastructure failure: #{exception.message}")
      Sidekiq.logger.error("Job details: #{msg.inspect}")
    end
  end
end
