# frozen_string_literal: true

class LockVerifyChildReactor < RubyReactor::Reactor
  input :order_id, :string

  with_lock(ttl: 120) { |inputs| "order:#{inputs[:order_id]}" }

  step :verify_ledger do
    argument :order_id, input(:order_id)
    run do |args|
      puts "[EXECUTION] LockVerifyChildReactor.verify_ledger - order_id: #{args[:order_id]}"
      Success(verified: true, order_id: args[:order_id])
    end
  end

  returns :verify_ledger
end
