# frozen_string_literal: true

class LockInlineContentionDemoReactor < RubyReactor::Reactor
  input :order_id do
    required(:order_id).filled(:string)
  end

  step :demonstrate_inline_contention do
    argument :order_id, input(:order_id)
    run do |args|
      lock_key = "order:#{args[:order_id]}"
      blocker = RubyReactor::Lock.new(lock_key, owner: "foreign-process", ttl: 120, wait: 0)
      blocker.acquire

      begin
        RubyReactor::Lock.new(lock_key, owner: "competing-run", ttl: 120, wait: 0).acquire
        RubyReactor.Failure("Expected Lock::AcquisitionError but lock was acquired")
      rescue RubyReactor::Lock::AcquisitionError => e
        puts "[EXECUTION] LockInlineContentionDemoReactor - inline contention on #{lock_key}"
        Success(
          inline_contention: true,
          lock_key: lock_key,
          message: e.message
        )
      ensure
        blocker.release
      end
    end
  end

  returns :demonstrate_inline_contention
end
