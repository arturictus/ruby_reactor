# frozen_string_literal: true

require "spec_helper"

# 011 R-05, H-3: a lock parked for a queue hop is leased past its TTL — the
# wait for a worker on another queue is unbounded — and `reattach` restores it.
RSpec.describe "RubyReactor::Lock#detach(lease:)" do
  let(:redis) { RubyReactor.configuration.storage_adapter.instance_variable_get(:@redis) }

  it "holds the key for the lease, and reattach restores the ttl" do
    lock = RubyReactor::Lock.new("lease-spec", owner: "run-1", ttl: 5, auto_extend: true)
    lock.acquire

    lock.detach(lease: 300)
    expect(redis.ttl("lock:lease-spec")).to be_within(2).of(300)

    lock.reattach
    expect(redis.ttl("lock:lease-spec")).to be_within(2).of(5)
  ensure
    lock&.release
  end

  it "leaves the ttl alone without a lease, as a park does" do
    lock = RubyReactor::Lock.new("lease-spec", owner: "run-1", ttl: 5, auto_extend: true)
    lock.acquire

    lock.detach
    expect(redis.ttl("lock:lease-spec")).to be <= 5
  ensure
    lock&.release
  end
end
