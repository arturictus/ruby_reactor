# frozen_string_literal: true

require "ruby_reactor"
require "sidekiq/testing"
require "debug"

# Configure Sidekiq logging to a file for debugging
Sidekiq.configure_server do |config|
  config.logger = Logger.new('log/sidekiq.log', 10, 1024000) # 10 files, 1MB each
  config.logger.level = Logger::DEBUG
end

Sidekiq.configure_client do |config|
  config.logger = Logger.new('log/sidekiq.log', 10, 1024000)
  config.logger.level = Logger::DEBUG
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
  config.before(:each) do
    Sidekiq::Testing.fake!
    Sidekiq::Worker.clear_all
  end

  config.after(:each) do
    Sidekiq::Testing.fake!
  end
end
