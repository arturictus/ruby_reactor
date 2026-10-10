# frozen_string_literal: true

# A map rolled back with one bulk call (010 US7). `charges` fans the payments
# out, 5 per throw. When :settle fails, the map's `undo_all` gets every
# completed charge (a lazy Enumerable, in index order) and refunds them with
# one provider call, instead of each element's own undo running once per
# payment. The steps before the map are undone after it, as usual.
#
# The refund log lives in Redis: the rollback may run in a Sidekiq worker.
class BulkRefundDemoReactor < RubyReactor::Reactor
  LOG = "demo:bulk_refund"

  class << self
    def record(kind, value)
      redis.rpush("#{LOG}:#{kind}", value)
    end

    def log(kind)
      redis.lrange("#{LOG}:#{kind}", 0, -1)
    end

    def reset!
      redis.del("#{LOG}:bulk_refunds", "#{LOG}:single_refunds")
    end

    private

    def redis
      @redis ||= Redis.new(url: RubyReactor.configuration.storage.redis_url)
    end
  end

  class LoadPaymentsStep < RubyReactor::Step
    input :count, optional: true

    def run
      Success((1..(inputs.count || 12)).map { |i| { id: "p#{i}", amount_cents: i * 100 } })
    end
  end

  class SettleStep < RubyReactor::Step
    input :fail, optional: true

    def run
      inputs.fail ? Failure("settlement batch rejected") : Success(:settled)
    end
  end

  input :count, optional: true
  input :fail_settle, optional: true

  step :load_payments, LoadPaymentsStep do
    argument :count, input(:count)
  end

  map :charges, BulkRefundChargeReactor do
    source result(:load_payments)
    argument :payment_id, element(:charges, :id)
    argument :amount_cents, element(:charges, :amount_cents)
    fan_out batch_size: 5

    # One provider call for the whole map: the ids of every completed charge.
    undo_all do |charges|
      BulkRefundDemoReactor.record(:bulk_refunds, charges.map { |charge| charge[:id] }.to_a.join(","))
    end
  end

  step :settle, SettleStep do
    argument :fail, input(:fail_settle)
    wait_for :charges
  end
end
