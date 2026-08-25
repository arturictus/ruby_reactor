# frozen_string_literal: true

require "spec_helper"

# Lock ownership is never shared across the async boundary: parent and
# child run CONCURRENTLY, so sharing an owner would put both inside the critical
# section at once — mutual exclusion silently broken, which is strictly worse
# than a stall. The one guaranteed deadlock is therefore caught at dispatch,
# loudly, instead of being left to a 30s timeout.
RSpec.describe "`async_reactor` lock deadlock guard" do
  before { AsyncReactorFixtures.reset! }

  for_each_async_backend do
    it "fails the dispatching step when the child declares a key the parent holds" do
      result = AsyncReactorLockCollisionReactor.run(account_id: "acct-1")

      expect(result).to be_a(RubyReactor::Failure)
      expect(result.message).to include("would deadlock")
    end

    it "names the lock key and both reactors" do
      result = AsyncReactorLockCollisionReactor.run(account_id: "acct-1")

      expect(result.message).to include("account:acct-1")
      expect(result.message).to include("AsyncLockedChildReactor")
      expect(result.message).to include("AsyncReactorLockCollisionReactor")
    end

    it "enumerates the three ranked remediations" do
      message = AsyncReactorLockCollisionReactor.run(account_id: "acct-1").message

      expect(message).to include("1. Use `compose`")
      expect(message).to include("2. Narrow the lock keys")
      expect(message).to include("3. Restructure")
    end

    it "never enqueues the child it refused to dispatch" do
      AsyncReactorLockCollisionReactor.run(account_id: "acct-1")

      expect(RubyReactor::RSpec::AsyncTestHelpers.pending_async_jobs).to be_empty
    end

    it "treats a single-slot semaphore as the same circular wait" do
      result = AsyncReactorSemaphoreCollisionReactor.run(account_id: "acct-1")

      expect(result).to be_a(RubyReactor::Failure)
      expect(result.message).to include("would deadlock")
    end

    it "dispatches normally when the child's key is different" do
      result = AsyncReactorDifferentKeyReactor.run(account_id: "acct-1")

      expect(result).to be_success
      expect(RubyReactor::RSpec::AsyncTestHelpers.pending_async_jobs.size).to eq(1)
    end

    it "releases the parent's lock afterwards, so the guard leaves nothing held" do
      AsyncReactorLockCollisionReactor.run(account_id: "acct-1")

      expect(redis.get("lock:account:acct-1")).to be_nil
    end
  end
end
