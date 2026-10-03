# frozen_string_literal: true

# A fan-out map inside a composed child (009 US2): :fulfil composes
# ComposedFanOutChildReactor, whose :ship_items map fans out. When the map
# completes, this run resumes and finishes. When :notify fails, the rollback
# travels through this run: every shipped item is unshipped (one job each),
# then the child's reservation is released.
#
# The logs live in Redis: items ship and unship in Sidekiq workers.
class ComposedFanOutDemoReactor < RubyReactor::Reactor
  LOG = "demo:composed_fan_out"

  class << self
    def record(kind, value)
      redis.rpush("#{LOG}:#{kind}", value)
    end

    def log(kind)
      redis.lrange("#{LOG}:#{kind}", 0, -1)
    end

    def shipped = log(:shipped)
    def unshipped = log(:unshipped)

    def reset!
      redis.del(*%i[shipped unshipped released].map { |kind| "#{LOG}:#{kind}" })
    end

    private

    def redis
      @redis ||= Redis.new(url: RubyReactor.configuration.storage.redis_url)
    end
  end

  class PrepareStep < RubyReactor::Step
    def run
      Success(%w[sku-1 sku-2 sku-3 sku-4 sku-5])
    end
  end

  class NotifyStep < RubyReactor::Step
    input :fail, optional: true

    def run
      return Failure("notification service unavailable") if inputs.fail

      Success(:notified)
    end
  end

  input :fail_notify, optional: true

  step :prepare, PrepareStep

  compose :fulfil, ComposedFanOutChildReactor do
    argument :skus, result(:prepare)
  end

  step :notify, NotifyStep do
    argument :fail, input(:fail_notify)
    wait_for :fulfil
  end
end
