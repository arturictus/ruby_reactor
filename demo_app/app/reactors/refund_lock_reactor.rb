# frozen_string_literal: true

# Demonstrates `with_lock` for at-most-one-runner concurrency control. Two
# refunds for the SAME order cannot run concurrently — the second snoozes
# until the first releases the lock. Refunds for DIFFERENT orders run in
# parallel (different lock keys).
#
# The lock is keyed by `order_id` and uses `auto_extend: true` so a slow
# refund step cannot let the TTL expire mid-flight.
class RefundLockReactor < RubyReactor::Reactor
  # In-memory log of refunds applied, for demo / spec assertions.
  class Log
    class << self
      def reset!
        @entries = []
      end

      def record(entry)
        @entries ||= []
        @entries << entry
      end

      def entries
        @entries ||= []
      end
    end
  end

  async true

  input :order_id do
    required(:order_id).filled(:string)
  end

  input :amount do
    required(:amount).filled(:integer, gt?: 0)
  end

  # Optional: simulated work duration in seconds so the demo can show the
  # lock being held across a slow step.
  input :delay, optional: true do
    optional(:delay).maybe(:float)
  end

  with_lock(ttl: 30, auto_extend: true) { |inputs| "refund:#{inputs[:order_id]}" }

  step :issue_refund do
    argument :order_id, input(:order_id)
    argument :amount, input(:amount)
    argument :delay, input(:delay)

    run do |args, _context|
      sleep(args[:delay]) if args[:delay] && args[:delay].positive?

      Log.record(order_id: args[:order_id], amount: args[:amount], at: Time.current.iso8601(3))

      Success(order_id: args[:order_id], refunded: args[:amount])
    end
  end

  returns :issue_refund
end
