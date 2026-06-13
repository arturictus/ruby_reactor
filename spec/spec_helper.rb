# frozen_string_literal: true

require "ruby_reactor"
require "ruby_reactor/rspec/matchers"
require "sidekiq/testing"
require "debug"
require "fileutils"
require "redis"

# Test-time Redis URL. The CI workflow maps 6379 → 6780 on the host; locally
# you can either match that mapping (e.g. `docker run -d --name rr-test-redis
# -p 6780:6379 redis:7-alpine`) or override via env.
REDIS_TEST_URL = ENV.fetch("RUBY_REACTOR_TEST_REDIS_URL", "redis://localhost:6780")

# Fail fast and loud if Redis isn't reachable — every spec needs it for
# context storage AND for the lock / semaphore / rate-limit / period
# integration tests.
begin
  Redis.new(url: REDIS_TEST_URL, timeout: 1).ping
rescue Redis::BaseConnectionError, Errno::ECONNREFUSED => e
  warn <<~MSG

    ============================================================
    Test Redis not reachable at #{REDIS_TEST_URL}
    (#{e.class}: #{e.message})

    Start one before running specs, e.g.:

      docker run -d --name rr-test-redis -p 6780:6379 redis:7-alpine

    Or point the suite at an existing Redis:

      RUBY_REACTOR_TEST_REDIS_URL=redis://localhost:6379 bundle exec rspec
    ============================================================

  MSG
  abort
end

# Shared `redis` accessor for tests that need to assert against Redis state
# directly (lock owner, semaphore tokens held, rate-limit counters, period
# markers, …). Use this rather than `Redis.new(url: ...)` so the URL stays
# in one place.
module RedisHelpers
  def redis
    @redis ||= Redis.new(url: REDIS_TEST_URL)
  end
end

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
  config.storage.redis_url = REDIS_TEST_URL
  config.async_router = RubyReactor::SidekiqAdapter
end

RSpec.configure do |config|
  RubyReactor::RSpec.configure(config)

  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.include RedisHelpers

  config.before do
    Sidekiq::Testing.fake!
    Sidekiq::Worker.clear_all

    # Each test starts with a clean Redis so lock owners, semaphore tokens,
    # rate-limit counters and period markers from prior tests can't leak.
    redis.flushdb

    # Reset snooze/jitter/cap knobs to documented defaults so a test that
    # overrides them doesn't bleed into the next.
    RubyReactor.configuration.lock_snooze_base_delay = 5
    RubyReactor.configuration.lock_snooze_jitter = 5
    RubyReactor.configuration.lock_snooze_max_attempts = 20

    # Fresh named rate-limit registry so a `config.rate_limits.register` in
    # one example can't leak a shared quota into the next.
    RubyReactor.configuration.instance_variable_set(:@rate_limits, RubyReactor::RateLimitRegistry.new)

    # Reset spec-fixture counters used by lock/period/rate-limit/skip specs.
    %i[PeriodicCounters RateLimitCounters SkippedStepCounters].each do |const|
      Object.const_get(const).reset if Object.const_defined?(const)
    end
  end

  config.after do
    Sidekiq::Testing.fake!
  end

  # Stub retry backoff delay to 0 to speed up tests
  config.before do
    allow(RubyReactor::RetryContext).to receive(:calculate_backoff_delay).and_return(0)
  end
end
