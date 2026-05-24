# frozen_string_literal: true

class SemaphoreInlineContentionDemoReactor < RubyReactor::Reactor
  input :request_id do
    required(:request_id).filled(:string)
  end

  step :demonstrate_inline_exhaustion do
    argument :request_id, input(:request_id)
    run do |args|
      semaphore_key = "payment_gateway"
      holders = 2.times.map { RubyReactor::Semaphore.new(semaphore_key, limit: 2, wait: 0) }
      holders.each(&:acquire)

      begin
        RubyReactor::Semaphore.new(semaphore_key, limit: 2, wait: 0).acquire
        RubyReactor.Failure("Expected Semaphore::AcquisitionError but token was acquired")
      rescue RubyReactor::Semaphore::AcquisitionError => e
        puts "[EXECUTION] SemaphoreInlineContentionDemoReactor - pool exhausted for #{semaphore_key}"
        Success(
          inline_contention: true,
          semaphore_key: semaphore_key,
          request_id: args[:request_id],
          message: e.message
        )
      ensure
        holders.each(&:release)
      end
    end
  end

  returns :demonstrate_inline_exhaustion
end
