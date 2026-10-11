# frozen_string_literal: true

# Distributed map rollback (009 US1). `charge_orders` fans out the orders, 10
# per throw. When :notify fails, every charged order is refunded by its own
# rollback job, again at most 10 per throw. The run stays `rolling_back` until
# the last refund reports, and only then is :load_orders undone.
#
# The charge and refund logs live in Redis: elements run (and roll back) in
# Sidekiq workers, not in the process that started the run.
class DistributedRefundDemoReactor < RubyReactor::Reactor
  LOG = "demo:distributed_refund"

  class << self
    def record(kind, order_id)
      redis.rpush("#{LOG}:#{kind}", order_id)
    end

    def charges
      redis.lrange("#{LOG}:charges", 0, -1)
    end

    def refunds
      redis.lrange("#{LOG}:refunds", 0, -1)
    end

    def reset!
      redis.del("#{LOG}:charges", "#{LOG}:refunds", "#{LOG}:failed_at")
    end

    # When :notify failed, i.e. when the rollback started (the benchmark's clock).
    def mark_failed!
      redis.set("#{LOG}:failed_at", Process.clock_gettime(Process::CLOCK_REALTIME).to_s)
    end

    def failed_at
      redis.get("#{LOG}:failed_at")&.to_f
    end

    private

    def redis
      @redis ||= DemoLog.store
    end
  end

  class LoadOrdersStep < RubyReactor::Step
    input :count, optional: true

    def run
      Success((1..(inputs.count || 40)).map { |i| { id: "o#{i}", amount_cents: i * 100 } })
    end

    def undo
      Success()
    end
  end

  class NotifyStep < RubyReactor::Step
    input :fail, optional: true

    def run
      if inputs.fail
        DistributedRefundDemoReactor.mark_failed!
        return Failure("notification service unavailable")
      end

      Success(:notified)
    end
  end

  input :count, optional: true
  input :fail_notify, optional: true

  step :load_orders, LoadOrdersStep do
    argument :count, input(:count)
  end

  map :charge_orders, DistributedRefundElementReactor do
    source result(:load_orders)
    argument :order_id, element(:charge_orders, :id)
    argument :amount_cents, element(:charge_orders, :amount_cents)
    fan_out batch_size: 10
  end

  step :notify, NotifyStep do
    argument :fail, input(:fail_notify)
    wait_for :charge_orders
  end
end
