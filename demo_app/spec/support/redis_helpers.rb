# frozen_string_literal: true

require "redis"

module RedisHelpers
  def redis
    @redis ||= Redis.new(url: RubyReactor.configuration.storage.redis_url)
  end

  # Redis is only in play as the storage or the Sidekiq queue; a Redis-free run
  # (active_record + active_job) must never connect to it (011 FR-006).
  def self.redis_in_use?
    RubyReactor.configuration.storage.adapter == :redis || ENV.fetch("RUBY_REACTOR_QUEUE", "sidekiq") == "sidekiq"
  end
end

RSpec.configure do |config|
  config.include RedisHelpers

  config.before do
    redis.flushdb if RedisHelpers.redis_in_use?

    RubyReactor.configuration.lock_snooze_base_delay = 5
    RubyReactor.configuration.lock_snooze_jitter = 5
    RubyReactor.configuration.lock_snooze_max_attempts = 20
  end

  # Specs tied to one backend skip, with a reason, under the other (011 R-17).
  config.before(:each, :redis_only) do
    skip "Redis storage only" unless RubyReactor.configuration.storage.adapter == :redis
  end
  config.before(:each, :active_record_only) do
    skip "ActiveRecord storage only" unless RubyReactor.configuration.storage.adapter == :active_record
  end
  config.before(:each, :sidekiq_only) do
    skip "Sidekiq queue only" unless ENV.fetch("RUBY_REACTOR_QUEUE", "sidekiq") == "sidekiq"
  end
end
