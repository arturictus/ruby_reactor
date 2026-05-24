# frozen_string_literal: true

class RateLimitDemoReactor < RubyReactor::Reactor
  input :account_id do
    required(:account_id).filled(:string)
  end

  input :hold_seconds, optional: true do
    optional(:hold_seconds).maybe(:integer, gteq?: 0)
  end

  with_rate_limit(limit: 3, period: :second) { |inputs| "api:#{inputs[:account_id]}" }
  async true

  step :call_external_api do
    argument :account_id, input(:account_id)
    argument :hold_seconds, input(:hold_seconds)
    run do |args|
      hold = args[:hold_seconds] || 5
      puts "[EXECUTION] RateLimitDemoReactor.call_external_api - account_id: #{args[:account_id]}, holding for #{hold}s"
      sleep hold
      Success(called: true, account_id: args[:account_id], held_for: hold)
    end
  end

  returns :call_external_api
end
