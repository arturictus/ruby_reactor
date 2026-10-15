# frozen_string_literal: true

# Where the demo reactors keep their side-effect logs (refunds issued, orders
# shipped…) so specs and rake tasks can show what ran. Redis when the demo has
# Redis (it may be read from a Sidekiq process); in a Redis-free run
# (active_record storage + active_job queue) jobs run in-process, so an
# in-memory store with the same few Redis calls is enough.
module DemoLog
  def self.store
    redis_in_use? ? Redis.new(url: RubyReactor.configuration.storage.redis_url) : MEMORY
  end

  def self.redis_in_use?
    RubyReactor.configuration.storage.adapter == :redis || ENV.fetch("RUBY_REACTOR_QUEUE", "sidekiq") == "sidekiq"
  end

  # The subset of redis-rb the demo reactors use.
  class Memory
    def initialize
      @data = {}
      @lock = Mutex.new
    end

    def rpush(key, value) = @lock.synchronize { (@data[key] ||= []) << value.to_s }.size
    def lrange(key, _start, _stop) = @lock.synchronize { (@data[key] || []).dup }
    def del(*keys) = @lock.synchronize { keys.count { |key| @data.delete(key) } }
    def set(key, value) = @lock.synchronize { @data[key] = value.to_s }
    def get(key) = @lock.synchronize { @data[key] }
  end

  MEMORY = Memory.new
end
