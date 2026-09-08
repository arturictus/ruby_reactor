Sidekiq.configure_server do |config|
  config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6380/1") }

  # Kick the RubyReactor recovery sweeper once the Sidekiq server boots. Only the
  # server runs recovery (not web/console/client processes). Idempotent — the
  # per-window claim collapses duplicate kicks across multiple server processes.
  config.on(:startup) { RubyReactor.start_sweeper! }
end

Sidekiq.configure_client do |config|
  config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6380/1") }
end
