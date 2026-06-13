# frozen_string_literal: true

class SemaphoreDemoReactor < RubyReactor::Reactor
  async true

  input :request_id, :string
  input :hold_seconds, :integer, optional: true, gteq?: 0

  with_semaphore(limit: 2, wait: 0) { |_inputs| "payment_gateway" }

  step :validate_request do
    argument :request_id, input(:request_id)
    run do |args|
      puts "[EXECUTION] SemaphoreDemoReactor.validate_request (async worker) - request_id: #{args[:request_id]}"
      Success(validated: true, request_id: args[:request_id])
    end
  end

  step :call_payment_gateway do
    argument :request_id, result(:validate_request, [:request_id])
    argument :hold_seconds, input(:hold_seconds)
    wait_for :validate_request
    run do |args|
      hold = args[:hold_seconds] || 10
      puts "[EXECUTION] SemaphoreDemoReactor.call_payment_gateway (async worker) - request_id: #{args[:request_id]}, holding slot for #{hold}s"
      sleep hold
      Success(charged: true, request_id: args[:request_id], held_for: hold)
    end
  end

  step :record_transaction do
    argument :charge, result(:call_payment_gateway)
    run do |args|
      puts "[EXECUTION] SemaphoreDemoReactor.record_transaction (async worker) - charge: #{args[:charge]}"
      Success(recorded: true, charge: args[:charge])
    end
  end

  returns :record_transaction
end
