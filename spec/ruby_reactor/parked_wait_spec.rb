# frozen_string_literal: true

require "spec_helper"

# Park-instead-of-block: inside a worker, `result(:name)` on a still-pending
# async unit frees the thread (Error::AsyncResultPending -> snooze) instead of
# blocking it, while exclusive lock / semaphore stay held across the gap.
RSpec.describe "parked async waits" do
  describe RubyReactor::Template::Result do
    let(:reactor_class) do
      Class.new(RubyReactor::Reactor) do
        def self.name = "ParkedWaitSpecReactor"
      end
    end

    def context_with_ref(inline:, dispatched_at: Time.now)
      context = RubyReactor::Context.new({}, reactor_class)
      context.inline_async_execution = inline
      context.composed_contexts[:child] = {
        name: :child,
        type: :async_reactor_ref,
        execution_id: "never-completes-#{SecureRandom.hex(4)}",
        reactor_class_name: "ParkedWaitSpecMissingChild",
        dispatched_at: dispatched_at
      }
      context
    end

    around do |example|
      original = RubyReactor.configuration.async_wait_timeout
      RubyReactor.configuration.async_wait_timeout = 0.3
      example.run
    ensure
      RubyReactor.configuration.async_wait_timeout = original
    end

    before { stub_const("RubyReactor::Template::Result::PARK_GRACE", 0.1) }

    it "raises AsyncResultPending inside a worker instead of blocking out the full timeout" do
      template = described_class.new(:child)

      expect { template.resolve(context_with_ref(inline: true)) }
        .to raise_error(RubyReactor::Error::AsyncResultPending, /parking/)
    end

    it "bounds the parked wait by async_park_timeout measured from dispatch" do
      template = described_class.new(:child)
      stale = context_with_ref(inline: true, dispatched_at: Time.now - 4000)

      expect { template.resolve(stale) }
        .to raise_error(RubyReactor::Error::AsyncWaitTimeoutError, /async_park_timeout/)
    end

    it "keeps the bounded blocking wait for synchronous callers" do
      template = described_class.new(:child)

      expect { template.resolve(context_with_ref(inline: false)) }
        .to raise_error(RubyReactor::Error::AsyncWaitTimeoutError, /async_wait_timeout/)
    end
  end

  describe "RubyReactor::Lock park support" do
    let(:key) { "park-spec-#{SecureRandom.hex(4)}" }

    it "keeps ownership across detach and re-adopts it via reattach without leaking the count" do
      first = RubyReactor::Lock.new(key, owner: "owner-1", ttl: 30, auto_extend: false)
      first.acquire
      first.detach

      adapter = RubyReactor.configuration.storage_adapter
      expect(adapter.lock_acquire("lock:#{key}", "someone-else", 30)).to be(false)

      resumed = RubyReactor::Lock.new(key, owner: "owner-1", ttl: 30, auto_extend: false)
      expect(resumed.reattach).to be(true)

      # Count stayed at 1, so one release fully frees the key.
      resumed.release
      expect(adapter.lock_acquire("lock:#{key}", "someone-else", 30)).to be(true)
      adapter.lock_release("lock:#{key}", "someone-else")
    end

    it "reports a lapsed ownership so the caller can fall back to a fresh acquire" do
      never_held = RubyReactor::Lock.new(key, owner: "owner-1", ttl: 30, auto_extend: false)

      expect(never_held.reattach).to be(false)
    end
  end

  describe "RubyReactor::Semaphore park support" do
    let(:key) { "park-sem-#{SecureRandom.hex(4)}" }

    after { RubyReactor.configuration.storage_adapter.semaphore_reset("semaphore:#{key}") }

    it "re-adopts a token still checked out and rejects one that was returned" do
      first = RubyReactor::Semaphore.new(key, limit: 1)
      first.acquire
      token = first.token

      resumed = RubyReactor::Semaphore.new(key, limit: 1)
      expect(resumed.reattach(token)).to be(true)

      resumed.release
      expect(RubyReactor::Semaphore.new(key, limit: 1).reattach(token)).to be(false)
    end
  end
end
