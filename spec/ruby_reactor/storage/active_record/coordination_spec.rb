# frozen_string_literal: true

require "spec_helper"

# 011 R-04–R-07: the Redis-shaped KV that the coordination scripts are ported
# onto. Each verb sequence runs against real Redis and against
# `Coordination.atomically`, and the results must match.
RSpec.describe "ActiveRecord coordination store", :active_record_only do # rubocop:disable RSpec/DescribeClass
  let(:coordination) { RubyReactor::Storage::ActiveRecordAdapter::Coordination }
  let(:entries) { RubyReactor::Storage::ActiveRecordAdapter::CoordinationEntry }

  # Runs `steps` (an Array of [verb, *args]) against Redis and the KV,
  # returning both result lists.
  def both(keys, steps)
    redis_results = steps.map { |verb, *args| redis_call(verb, *args) }
    kv_results = coordination.atomically(keys) { |kv| steps.map { |verb, *args| kv_call(kv, verb, *args) } }
    [redis_results, kv_results]
  end

  def redis_call(verb, *args)
    case verb
    when :set
      key, val, opts = args
      opts ||= {}
      return redis.set(key, val, nx: opts[:nx], ex: opts[:ex], keepttl: opts[:keepttl]) ? true : false
    when :exists then return redis.exists?(*args)
    when :expire then return redis.expire(*args)
    when :rpush then return redis.rpush(args[0], args[1..])
    when :lrange then return redis.lrange(args[0], 0, -1)
    end
    redis.public_send(verb, *args)
  end

  def kv_call(kv, verb, *args)
    case verb
    when :set
      key, val, opts = args
      return kv.set(key, val, **(opts || {}))
    when :rpush then return kv.rpush(args[0], *args[1..])
    end
    kv.public_send(verb, *args)
  end

  it "matches Redis for strings and counters" do
    steps = [[:get, "s"], [:set, "s", "a"], [:get, "s"], [:set, "s", "b", { nx: true }], [:get, "s"],
             [:incr, "n"], [:incrby, "n", 4], [:decr, "n"], [:get, "n"], [:exists, "n"], [:exists, "zz"],
             [:del, "s"], [:del, "s"], [:get, "s"], [:ttl, "n"], [:ttl, "zz"],
             [:set, "t", "x", { ex: 100 }], [:ttl, "t"], [:incr, "t2"], [:expire, "t2", 50], [:incr, "t2"],
             [:ttl, "t2"], [:set, "t2", "9", { keepttl: true }], [:ttl, "t2"], [:set, "t2", "1"], [:ttl, "t2"]]

    redis_results, kv_results = both(%w[s n zz t t2], steps)

    expect(kv_results).to eq(redis_results)
  end

  it "matches Redis for hashes" do
    steps = [[:hset, "h", "a", "1"], [:hset, "h", "a", "2"], [:hset, "h", "b", "3"], [:hget, "h", "a"],
             [:hexists, "h", "b"], [:hexists, "h", "c"], [:hincrby, "h", "n", 5], [:hlen, "h"], [:hkeys, "h"],
             [:hdel, "h", "a"], [:hdel, "h", "a"], [:hgetall, "h"], [:hdel, "h", "b"], [:hdel, "h", "n"],
             [:exists, "h"]]

    redis_results, kv_results = both(%w[h], steps)

    expect(kv_results).to eq(redis_results)
  end

  it "matches Redis for lists and sets" do
    steps = [[:rpush, "l", "a", "b"], [:rpush, "l", "c"], [:llen, "l"], [:lpop, "l"], [:lrange, "l"],
             [:lpop, "l"], [:lpop, "l"], [:lpop, "l"], [:exists, "l"],
             [:sadd, "st", "x"], [:sadd, "st", "x"], [:sadd, "st", "y"], [:sismember, "st", "x"], [:scard, "st"],
             [:srem, "st", "x"], [:srem, "st", "x"], [:smembers, "st"], [:srem, "st", "y"], [:exists, "st"]]

    redis_results, kv_results = both(%w[l st], steps)

    expect(kv_results).to eq(redis_results)
  end

  it "persists across transactions, including each key's own expiry" do
    coordination.atomically(%w[a b]) do |kv|
      kv.set("a", "1", ex: 60)
      kv.hset("b", "f", "v")
    end

    coordination.atomically(%w[a b]) do |kv|
      expect(kv.get("a")).to eq("1")
      expect(kv.ttl("a")).to be_within(2).of(60)
      expect(kv.hget("b", "f")).to eq("v")
      expect(kv.ttl("b")).to eq(-1)
    end
  end

  it "judges expiry by the database clock, not this process's" do
    coordination.atomically(%w[k]) { |kv| kv.set("k", "v", ex: 60) }
    allow(Time).to receive(:now).and_return(Time.at(Time.now.to_i + 86_400))

    expect(coordination.atomically(%w[k]) { |kv| kv.get("k") }).to eq("v")
  end

  it "reads an expired key as absent" do
    coordination.atomically(%w[k]) { |kv| kv.set("k", "v", ex: 1) }
    sleep 1.2

    expect(coordination.atomically(%w[k]) { |kv| [kv.exists("k"), kv.ttl("k")] }).to eq([false, -2])
  end

  it "retries a deadlock twice, then gives up" do
    calls = 0
    result = coordination.atomically(%w[k]) do
      calls += 1
      raise ActiveRecord::Deadlocked, "deadlock" if calls < 3

      :done
    end
    expect([result, calls]).to eq([:done, 3])

    calls = 0
    expect do
      coordination.atomically(%w[k]) do
        calls += 1
        raise ActiveRecord::Deadlocked, "deadlock"
      end
    end.to raise_error(ActiveRecord::Deadlocked)
    expect(calls).to eq(3)
  end

  it "never retries a lock-wait timeout" do
    calls = 0
    expect do
      coordination.atomically(%w[k]) do
        calls += 1
        raise ActiveRecord::LockWaitTimeout, "timeout"
      end
    end.to raise_error(ActiveRecord::LockWaitTimeout)
    expect(calls).to eq(1)
  end

  it "serializes concurrent read-modify-writes on the same key" do
    threads = Array.new(2) do
      Thread.new { 100.times { coordination.atomically(%w[counter]) { |kv| kv.incr("counter") } } }
    end
    threads.each(&:join)

    expect(coordination.atomically(%w[counter]) { |kv| kv.get("counter") }).to eq("200")
  end

  it "peeks without inserting rows, and reads expired keys as absent" do
    coordination.atomically(%w[k]) { |kv| kv.set("k", "v", ex: 60) }

    expect(coordination.peek(%w[k nope]) { |kv| [kv.get("k"), kv.ttl("k"), kv.exists("nope")] })
      .to match(["v", be_within(2).of(60), false])
    expect(entries.where(key: "nope").count).to eq(0)
    expect { coordination.peek(%w[k]) { |kv| kv.set("k", "x") } }.to raise_error(ActiveRecord::ReadOnlyError)
  end

  it "peeks without waiting for a row another transaction has locked" do
    skip "SQLite has no row locks; its writers are serialized" if ActiveRecord::Base.connection_db_config.adapter == "sqlite3"
    coordination.atomically(%w[k]) { |kv| kv.set("k", "v") }
    locked = Queue.new
    release = Queue.new
    holder = Thread.new do
      coordination.atomically(%w[k]) do
        locked << true
        release.pop
      end
    end
    locked.pop

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect(coordination.peek(%w[k]) { |kv| kv.get("k") }).to eq("v")
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
  ensure
    release&.push(true)
    holder&.join
  end

  it "purges expired and emptied rows" do
    coordination.atomically(%w[old empty live]) do |kv|
      kv.set("old", "1", ex: 1)
      kv.set("live", "1", ex: 60)
    end
    sleep 1.2

    expect(coordination.purge_expired(limit: 10)).to eq(2)
    expect(entries.pluck(:key)).to eq(["live"])
  end
end
