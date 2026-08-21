# frozen_string_literal: true

# Bootstrap for the LIVE sidekiq process the orchestration lane boots
# (spec/support/real_async_backend.rb). Deliberately does not load spec_helper:
# this process is a worker, not a spec runner, and pulling RSpec in here would
# be exactly the mock/real blurring the lane exists to avoid.

require "sidekiq"
require "ruby_reactor"

REDIS_URL = ENV.fetch("RUBY_REACTOR_TEST_REDIS_URL", "redis://localhost:6780")

Sidekiq.configure_server do |config|
  config.redis = { url: REDIS_URL }
  config.logger = Logger.new("log/sidekiq-live.log", 3, 1_024_000)
end

RubyReactor.configure do |config|
  config.storage.adapter = :redis
  config.storage.redis_url = REDIS_URL
  config.async_router = RubyReactor::Adapters::Sidekiq::Router
end

# Fixture reactors only — these are plain reactor classes with no RSpec
# dependency, which is why the orchestration-lane fixtures live under
# spec/support/reactors/ rather than inline in a spec file.
Dir[File.expand_path("reactors/*.rb", __dir__)].sort.each { |file| require file }
