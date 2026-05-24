# frozen_string_literal: true

class LockDemoReactor < RubyReactor::Reactor
  async true

  input :order_id do
    required(:order_id).filled(:string)
  end

  input :hold_seconds, optional: true do
    optional(:hold_seconds).maybe(:integer, gteq?: 0)
  end

  with_lock(ttl: 120) { |inputs| "order:#{inputs[:order_id]}" }

  step :prepare_refund do
    argument :order_id, input(:order_id)
    run do |args|
      puts "[EXECUTION] LockDemoReactor.prepare_refund - order_id: #{args[:order_id]}"
      Success(prepared: true, order_id: args[:order_id])
    end
  end

  compose :verify_ledger, LockVerifyChildReactor do
    argument :order_id, input(:order_id)
  end

  step :process_refund do
    argument :order_id, input(:order_id)
    argument :hold_seconds, input(:hold_seconds)
    wait_for :verify_ledger
    run do |args|
      hold = args[:hold_seconds] || 30
      puts "[EXECUTION] LockDemoReactor.process_refund - holding lock for #{hold}s on order #{args[:order_id]}"
      sleep hold
      Success(refunded: true, order_id: args[:order_id], held_for: hold)
    end
  end

  step :finalize_refund do
    argument :refund, result(:process_refund)
    run do |args|
      puts "[EXECUTION] LockDemoReactor.finalize_refund - refund: #{args[:refund]}"
      Success(finalized: true, refund: args[:refund])
    end
  end

  returns :finalize_refund
end
