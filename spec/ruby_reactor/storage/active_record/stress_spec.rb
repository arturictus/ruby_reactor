# frozen_string_literal: true

require "spec_helper"

# 011 SC-006: coordination guarantees under real multi-process contention.
# Run with `--tag stress` on PostgreSQL and MySQL (release checklist, quickstart §8).
RSpec.describe "ActiveRecord coordination under multi-process contention", :active_record_only, :stress do
  let(:adapter) { RubyReactor.configuration.storage_adapter }
  let(:coordination) { RubyReactor::Storage::ActiveRecordAdapter::Coordination }
  let(:processes) { 4 }
  let(:attempts) { 250 }

  before do
    skip "SQLite is single-host only" if ActiveRecord::Base.connection_db_config.adapter == "sqlite3"
  end

  def counter(key, delta) = coordination.atomically([key]) { |kv| kv.incrby(key, delta) }
  def read(key) = coordination.peek([key]) { |kv| kv.get(key).to_i }

  # Forks `processes` workers running the block with their index; fails the
  # example if any worker raised.
  def in_processes
    pids = Array.new(processes) do |worker|
      fork do
        yield worker
        exit!(0)
      rescue StandardError => e
        warn("stress worker #{worker}: #{e.class}: #{e.message}")
        exit!(1)
      end
    end
    statuses = pids.map { |pid| Process.wait2(pid).last }
    expect(statuses).to all(be_success)
  end

  it "never grants a lock to two holders at once" do
    in_processes do |worker|
      attempts.times do
        next unless adapter.lock_acquire("lock:stress", "w#{worker}", 5)

        counter("stress:violations", 1) if counter("stress:holders", 1) > 1
        counter("stress:holders", -1)
        adapter.lock_release("lock:stress", "w#{worker}")
      end
    end

    expect(read("stress:violations")).to eq(0)
  end

  it "never lets a semaphore exceed its limit" do
    adapter.semaphore_init("semaphore:stress", 3)
    in_processes do
      attempts.times do
        token = adapter.semaphore_acquire("semaphore:stress")
        next unless token

        counter("stress:violations", 1) if counter("stress:holders", 1) > 3
        counter("stress:holders", -1)
        adapter.semaphore_release("semaphore:stress", token, 3)
      end
    end

    expect(read("stress:violations")).to eq(0)
    expect(adapter.semaphore_state("stress")).to eq(available: 3, held: 0, limit: 3)
  end

  it "allows exactly the limit through a rate-limit window" do
    now = Time.now.to_i
    key = "rate:stress:3600:#{now / 3600}"
    in_processes do
      attempts.times do
        allowed, = adapter.rate_limit_check_and_increment([key], [now, 3600, 100, 3600])
        counter("stress:allowed", 1) if allowed == 1
      end
    end

    expect(read("stress:allowed")).to eq(100)
  end

  it "runs ordered-lock nonces strictly in order" do
    nonces = Array.new(40) { adapter.ordered_lock_assign("stress").first }
    in_processes do |worker|
      nonces.select { |n| n % processes == worker }.each do |nonce|
        sleep 0.005 until adapter.ordered_lock_can_proceed("stress", nonce: nonce, poison_pill_timeout: 3600)
                                 .first == "go"
        coordination.atomically(["stress:order"]) { |kv| kv.rpush("stress:order", nonce) }
        adapter.ordered_lock_advance("stress", nonce: nonce)
      end
    end

    expect(coordination.peek(["stress:order"]) { |kv| kv.lrange("stress:order") }.map(&:to_i)).to eq(nonces)
  end
end
