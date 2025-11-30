# frozen_string_literal: true

require "ruby_reactor"
require "sidekiq/testing"
require "debug"
require "fileutils"
require "redis"

# Load support files
Dir[File.expand_path("support/**/*.rb", __dir__)].each { |f| require f }

# Ensure log directory exists
FileUtils.mkdir_p("log")

# Configure Sidekiq logging to a file for debugging
Sidekiq.configure_server do |config|
  config.logger = Logger.new("log/sidekiq.log", 10, 1_024_000) # 10 files, 1MB each
  config.logger.level = Logger::DEBUG
end

Sidekiq.configure_client do |config|
  config.logger = Logger.new("log/sidekiq.log", 10, 1_024_000)
  config.logger.level = Logger::DEBUG
end

RubyReactor.configure do |config|
  config.storage.adapter = :redis
  config.storage.redis_url = "redis://localhost:6780"
  config.async_router = Support::WorkerMock
end

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Configure Sidekiq for testing
  config.before do
    Sidekiq::Testing.fake!
    Sidekiq::Worker.clear_all

    # Flush Redis
    redis = Redis.new(url: "redis://localhost:6780")
    redis.flushdb
  end

  config.after do
    Sidekiq::Testing.fake!
  end

  # Stub retry backoff delay to 0 to speed up tests
  config.before do
    allow(RubyReactor::RetryContext).to receive(:calculate_backoff_delay).and_return(0)
  end
end
