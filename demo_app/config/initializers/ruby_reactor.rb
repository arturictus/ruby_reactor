RubyReactor.configure do |config|
  # Redis configuration for state persistence
  config.storage.adapter = :redis
  config.storage.redis_url = ENV.fetch("REDIS_URL", "redis://localhost:6380/1") # Use DB 1 to avoid conflicts
  config.storage.redis_options = { timeout: 1 }

  # Sidekiq configuration for async execution
  config.sidekiq_queue = :default
  config.sidekiq_retry_count = 3
  
  # Logger configuration
  config.logger = Logger.new($stdout)

  # Register OpenTelemetry middleware
  config.middlewares = [RubyReactor::OpenTelemetry]
end
