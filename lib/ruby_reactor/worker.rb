# frozen_string_literal: true

require "sidekiq"

module RubyReactor
  # Sidekiq worker for executing RubyReactor reactors asynchronously
  # with non-blocking retry capabilities
  class Worker
    include Sidekiq::Worker

    # Enable Sidekiq retries for infrastructure failures only
    sidekiq_options retry: RubyReactor::Configuration.sidekiq_retry_count, dead: false, queue: RubyReactor::Configuration.sidekiq_queue

    sidekiq_retries_exhausted do |msg, ex|
      # Handle infrastructure failures (network, Redis, etc.)
      log_infrastructure_failure(msg, ex)
    end

    def perform(serialized_context)
      context = Context.deserialize_from_retry(serialized_context)

      # Resume execution from the failed step
      executor = Executor.new(context.reactor_class, context.inputs)
      executor.resume_execution(context)
    rescue StandardError => e
      # Log unexpected errors but don't retry - our custom logic handles retries
      log_unexpected_error(e, context)
      raise
    end

    private

    def log_infrastructure_failure(msg, ex)
      Sidekiq.logger.error("RubyReactor infrastructure failure: #{ex.message}")
      Sidekiq.logger.error("Job details: #{msg.inspect}")
    end

    def log_unexpected_error(error, context)
      Sidekiq.logger.error("RubyReactor unexpected error: #{error.message}")
      Sidekiq.logger.error("Context: #{context.inspect}") if context
    end
  end
end