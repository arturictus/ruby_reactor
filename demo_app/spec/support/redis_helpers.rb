# frozen_string_literal: true

require "redis"

module RedisHelpers
  def redis
    @redis ||= Redis.new(url: RubyReactor.configuration.storage.redis_url)
  end
end

RSpec.configure do |config|
  config.include RedisHelpers

  config.before do
    redis.flushdb

    RubyReactor.configuration.lock_snooze_base_delay = 5
    RubyReactor.configuration.lock_snooze_jitter = 5
    RubyReactor.configuration.lock_snooze_max_attempts = 20
  end
end
