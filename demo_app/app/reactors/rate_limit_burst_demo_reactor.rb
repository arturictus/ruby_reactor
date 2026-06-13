# frozen_string_literal: true

class RateLimitBurstDemoReactor < RubyReactor::Reactor
  input :account_id, :string

  step :burst_calls do
    argument :account_id, input(:account_id)
    run do |args|
      attempts = 4.times.map do |i|
        begin
          result = RateLimitBurstDemoReactor.run_rate_limit_demo(account_id: args[:account_id], hold_seconds: 0)
          { attempt: i + 1, status: :allowed, success: result.success? }
        rescue RubyReactor::RateLimit::ExceededError => e
          {
            attempt: i + 1,
            status: :exceeded,
            period: e.period_name,
            limit: e.limit,
            message: e.message
          }
        end
      end

      puts "[EXECUTION] RateLimitBurstDemoReactor - burst complete for #{args[:account_id]}"
      Success(account_id: args[:account_id], attempts: attempts)
    end
  end

  returns :burst_calls

  class << self
    def run_rate_limit_demo(account_id:, hold_seconds: 0)
      inputs = { account_id: account_id, hold_seconds: hold_seconds }
      context = RubyReactor::Context.new(inputs, RateLimitDemoReactor)
      context.inline_async_execution = true
      RateLimitDemoReactor.new(context).run(inputs)
    end
  end
end
