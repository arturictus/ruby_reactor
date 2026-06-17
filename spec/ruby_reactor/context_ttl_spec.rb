# frozen_string_literal: true

require "spec_helper"

# Phase 4: storage is load-bearing, so a long-running / snoozed context must not
# expire mid-flight. Every store_context write re-stamps the TTL with
# config.context_ttl, so repeated checkpoints keep the key alive indefinitely.
RSpec.describe "Context TTL refresh" do
  let(:storage) { RubyReactor.configuration.storage_adapter }
  let(:reactor_class) { Class.new { def self.name = "TtlTestReactor" } }

  around do |example|
    original = RubyReactor.configuration.context_ttl
    RubyReactor.configuration.context_ttl = 50
    example.run
    RubyReactor.configuration.context_ttl = original
  end

  def key_for(context_id)
    "reactor:TtlTestReactor:context:#{context_id}"
  end

  it "stamps the context key with config.context_ttl on store" do
    context = RubyReactor::Context.new({ n: 1 }, reactor_class)
    storage.store_context(context.context_id, RubyReactor::ContextSerializer.serialize(context), reactor_class.name)

    ttl = redis.ttl(key_for(context.context_id))
    expect(ttl).to be > 40
    expect(ttl).to be <= 50
  end

  it "re-stamps the TTL on every checkpoint so it never decays toward expiry" do
    context = RubyReactor::Context.new({ n: 1 }, reactor_class)
    executor = RubyReactor::Executor.new(reactor_class, {}, context)

    executor.checkpoint!
    redis.expire(key_for(context.context_id), 5) # simulate time passing toward expiry
    expect(redis.ttl(key_for(context.context_id))).to be <= 5

    executor.checkpoint! # a later save must refresh it back to the full window
    expect(redis.ttl(key_for(context.context_id))).to be > 40
  end
end
