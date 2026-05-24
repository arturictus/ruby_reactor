# frozen_string_literal: true

class SemaphoreDemoReactor < RubyReactor::Reactor
  async true

  input :request_id do
    required(:request_id).filled(:string)
  end

  input :hold_seconds, optional: true do
    optional(:hold_seconds).maybe(:integer, gteq?: 0)
  end

  with_semaphore(limit: 2, wait: 0) { |_inputs| "payment_gateway" }

  step :call_payment_gateway do
    argument :request_id, input(:request_id)
    argument :hold_seconds, input(:hold_seconds)
    run do |args|
      hold = args[:hold_seconds] || 30
      puts "[EXECUTION] SemaphoreDemoReactor.call_payment_gateway - request_id: #{args[:request_id]}, holding slot for #{hold}s"
      sleep hold
      Success(charged: true, request_id: args[:request_id], held_for: hold)
    end
  end

  returns :call_payment_gateway
end
