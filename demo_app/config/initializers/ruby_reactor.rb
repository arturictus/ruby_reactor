# Storage and queue backend are chosen per environment, so the same demo runs
# on both storage adapters (specs/011):
#
#   RUBY_REACTOR_STORAGE=redis|active_record   (default redis)
#   RUBY_REACTOR_QUEUE=sidekiq|active_job      (default sidekiq)
#
# With active_record + active_job nothing talks to Redis. DATABASE_URL picks the
# database engine through Rails' usual database.yml merge.
storage = ENV.fetch("RUBY_REACTOR_STORAGE", "redis")
queue = ENV.fetch("RUBY_REACTOR_QUEUE", "sidekiq")

RubyReactor.configure do |config|
  # Redis URL for Redis storage (and the specs' Redis helpers); unused by a
  # Redis-free run.
  config.storage.redis_url = ENV.fetch("REDIS_URL", "redis://localhost:6380/1") # Use DB 1 to avoid conflicts
  config.storage.redis_options = { timeout: 1 }

  if storage == "active_record"
    # Reactor state in the app's primary database (its own connection pool).
    config.storage.adapter = :active_record
  else
    config.storage.adapter = :redis
  end

  if queue == "active_job"
    config.async_router = RubyReactor::Adapters::ActiveJob::Router
  else
    # Sidekiq configuration for async execution
    config.sidekiq_queue = :default
    config.sidekiq_retry_count = 3
  end

  # Logger configuration
  config.logger = Logger.new($stdout)

  # Register OpenTelemetry middleware
  config.middlewares = [RubyReactor::OpenTelemetry]
end

# ActiveJob backend: the :test adapter in specs (drain_async_jobs drains it);
# elsewhere :async runs jobs in-process, so the rake demos need no worker.
if queue == "active_job"
  ActiveJob::Base.queue_adapter = Rails.env.test? ? :test : :async
end
