# frozen_string_literal: true

require "spec_helper"

module QueryContractSpec
  class Charge < RubyReactor::Reactor
    input :user_id
    input :card_token, redact: true, optional: true
    input :meta, optional: true
    input :note, optional: true
  end

  class Refund < RubyReactor::Reactor
    input :user_id
  end
end

# The storage adapter contract (specs/011 contracts/storage-adapter.md). It runs
# against whichever adapter the suite selected (RUBY_REACTOR_TEST_STORAGE), so
# CI's storage matrix proves every adapter honors the same semantics.
RSpec.describe "Storage adapter contract" do
  let(:adapter) { RubyReactor.configuration.storage_adapter }
  let(:klass) { "ContractSpec::Reactor" }

  def context_json(id, **extra)
    { "context_id" => id, "reactor_class" => klass, "started_at" => Time.now.iso8601,
      "status" => "running", "inputs" => {} }.merge(extra.transform_keys(&:to_s)).to_json
  end

  describe "surface" do
    # Implemented on the base class on purpose (shared by every adapter).
    let(:base_implemented) { %i[determine_status execution_evidence? purge_expired_coordination] }
    # Capability-detected (dashboard filters), so not declared on the base.
    let(:capabilities) { %i[query_executions] }

    it "implements every method the base Adapter declares" do
      declared = RubyReactor::Storage::Adapter.public_instance_methods(false) - base_implemented
      unimplemented = declared.select do |m|
        adapter.class.instance_method(m).owner == RubyReactor::Storage::Adapter
      end
      expect(unimplemented).to be_empty
    end

    it "exposes nothing callable that the base Adapter does not declare" do
      callable = adapter.class.public_instance_methods - Object.public_instance_methods - %i[reset!]
      undeclared = callable - RubyReactor::Storage::Adapter.public_instance_methods - capabilities
      expect(undeclared).to be_empty
    end
  end

  describe "contexts" do
    it "stores, retrieves by id and class, and finds by id alone" do
      adapter.store_context("ctx-1", context_json("ctx-1", foo: "bar"), klass)

      expect(adapter.retrieve_context("ctx-1", klass)).to include("context_id" => "ctx-1", "foo" => "bar")
      expect(adapter.find_context_by_id("ctx-1")).to include("context_id" => "ctx-1")
    end

    it "returns nil under a different storage name, and for unknown ids" do
      adapter.store_context("ctx-1", context_json("ctx-1"), klass)

      expect(adapter.retrieve_context("ctx-1", "Other")).to be_nil
      expect(adapter.retrieve_context("nope", klass)).to be_nil
      expect(adapter.find_context_by_id("nope")).to be_nil
    end

    it "last writer wins" do
      adapter.store_context("ctx-1", context_json("ctx-1", v: 1), klass)
      adapter.store_context("ctx-1", context_json("ctx-1", v: 2), klass)

      expect(adapter.retrieve_context("ctx-1", klass)["v"]).to eq(2)
    end

    it "deletes" do
      adapter.store_context("ctx-1", context_json("ctx-1"), klass)
      adapter.delete_context("ctx-1", klass)

      expect(adapter.retrieve_context("ctx-1", klass)).to be_nil
    end

    it "scans top-level runs only, plus dispatched children when asked" do
      adapter.store_context("top", context_json("top"), klass)
      adapter.store_context("child", context_json("child", parent_context_id: "top"), klass)
      adapter.store_context("async-child", context_json("async-child", parent_context_id: "top",
                                                                       private_data: { async_dispatched: true }), klass)

      expect(adapter.scan_reactors(count: 10).map { |r| r[:id] }).to eq(["top"])
      expect(adapter.scan_reactors(count: 10, include_dispatched_children: true).map { |r| r[:id] })
        .to contain_exactly("top", "async-child")
      expect(adapter.scan_reactors(count: 10).first).to include(class: klass, status: "running")
    end

    it "pages through every top-level run exactly once" do
      %w[a b c].each { |id| adapter.store_context(id, context_json(id), klass) }

      first = adapter.scan_reactors_page(cursor: "0", count: 2)
      second = adapter.scan_reactors_page(cursor: first[:cursor], count: 2)

      expect(first[:reactors].size).to eq(2)
      expect(first[:cursor]).not_to eq("0")
      expect((first[:reactors] + second[:reactors]).map { |r| r[:id] }).to contain_exactly("a", "b", "c")
      expect(second[:cursor]).to eq("0")
    end
  end

  describe "correlation ids" do
    it "is first-wins: the same context is a no-op, a different one raises" do
      adapter.store_correlation_id("order-1", "ctx-1", klass)
      adapter.store_correlation_id("order-1", "ctx-1", klass)

      expect(adapter.retrieve_context_id_by_correlation_id("order-1", klass)).to eq("ctx-1")
      expect { adapter.store_correlation_id("order-1", "ctx-2", klass) }
        .to raise_error(RubyReactor::Error::ValidationError, /already exists/)
    end

    it "deletes" do
      adapter.store_correlation_id("order-1", "ctx-1", klass)
      adapter.delete_correlation_id("order-1", klass)

      expect(adapter.retrieve_context_id_by_correlation_id("order-1", klass)).to be_nil
    end
  end

  describe "async step results" do
    it "stores, retrieves and scans records" do
      adapter.store_step_result("ctx-1", "send", { "status" => "dispatched" }, klass)
      adapter.store_step_result("ctx-1", "send", { "status" => "completed", "value" => 1 }, klass)

      expect(adapter.retrieve_step_result("ctx-1", "send", klass)).to eq("status" => "completed", "value" => 1)
      expect(adapter.retrieve_step_result("ctx-1", "other", klass)).to be_nil
      expect(adapter.scan_step_results(count: 10)).to include("status" => "completed", "value" => 1)
    end
  end

  describe "maps" do
    it "stores the owner ids, batch_size and atomic in the metadata" do
      adapter.initialize_map_operation("p1:m", 3, "P", reactor_class_info: { "type" => "class", "name" => "E" },
                                                       owner_context_id: "root", owner_reactor_class_name: "Root",
                                                       batch_size: 2, atomic: true)

      expect(adapter.retrieve_map_metadata("p1:m", "P")).to include(
        "owner_context_id" => "root", "owner_reactor_class_name" => "Root", "batch_size" => 2, "atomic" => true
      )
      expect(adapter.scan_maps(count: 10).map { |meta| meta["map_id"] }).to eq(["p1:m"])
    end

    it "claims the owner signal once per map" do
      expect(adapter.claim_map_owner_signal("p1:m", "P")).to be(true)
      expect(adapter.claim_map_owner_signal("p1:m", "P")).to be(false)
    end

    it "returns post-change counter values" do
      adapter.set_map_counter("p1:m", 5, "P")

      expect(adapter.decrement_map_counter_by("p1:m", 2, "P")).to eq(3)
      expect(adapter.decrement_map_counter("p1:m", "P")).to eq(2)
      expect(adapter.increment_map_counter("p1:m", "P")).to be_truthy
    end

    it "keeps the first offset and increments it" do
      expect(adapter.retrieve_map_offset("p1:m", "P")).to be_nil
      expect(adapter.set_map_offset_if_not_exists("p1:m", 5, "P")).to be(true)
      expect(adapter.set_map_offset_if_not_exists("p1:m", 9, "P")).to be(false)
      expect(adapter.increment_map_offset("p1:m", 3, "P")).to eq(8)
      expect(adapter.retrieve_map_offset("p1:m", "P").to_i).to eq(8)
    end

    it "keeps the first failed element" do
      adapter.store_map_failed_context_id("p1:m", "first", "P")
      adapter.store_map_failed_context_id("p1:m", "second", "P")

      expect(adapter.retrieve_map_failed_context_id("p1:m", "P")).to eq("first")
    end

    it "overwrites result slots, reads them aligned, and reports the missing ones" do
      adapter.store_map_result("p1:m", 0, { "v" => 0 }, "P")
      adapter.store_map_result("p1:m", 2, { "v" => 1 }, "P")
      adapter.store_map_result("p1:m", 2, { "v" => 2 }, "P")

      expect(adapter.retrieve_map_results("p1:m", "P")).to eq([{ "v" => 0 }, { "v" => 2 }])
      expect(adapter.retrieve_map_results_batch("p1:m", "P", offset: 1, limit: 2)).to eq([{ "v" => 2 }])
      expect(adapter.retrieve_map_result_slots("p1:m", "P", [2, 1, 0])).to eq([{ "v" => 2 }, nil, { "v" => 0 }])
      expect(adapter.count_map_results("p1:m", "P")).to eq(2)
      expect(adapter.missing_map_indices("p1:m", 4, "P")).to eq([1, 3])
    end

    it "keeps element ids in append order" do
      %w[a b c].each { |id| adapter.store_map_element_context_id("p1:m", id, "P") }

      expect(adapter.retrieve_map_element_context_ids("p1:m", "P")).to eq(%w[a b c])
      expect(adapter.retrieve_map_element_context_id("p1:m", "P", index: -1)).to eq("c")
      expect(adapter.retrieve_map_element_context_id("p1:m", "P", index: 0)).to eq("a")
    end
  end

  # 009 DM §5: the map rollback records.
  describe "map rollback records" do
    before { %w[a b c d e].each { |id| adapter.store_map_element_context_id("p1:m", id, "P") } }

    it "reads element ids by tail position, anchored at the total the rollback started with" do
      expect(adapter.count_map_element_context_ids("p1:m", "P")).to eq(5)
      expect(adapter.retrieve_map_element_context_ids_from_tail("p1:m", "P", 0, 2, total: 5)).to eq(%w[e d])
      expect(adapter.retrieve_map_element_context_ids_from_tail("p1:m", "P", 3, 5, total: 5)).to eq(%w[b a])
      adapter.store_map_element_context_id("p1:m", "late", "P")
      expect(adapter.retrieve_map_element_context_ids_from_tail("p1:m", "P", 0, 1, total: 5)).to eq(%w[e])
      expect(adapter.retrieve_map_element_context_ids_from_tail("p1:m", "P", 5, 2, total: 5)).to eq([])
    end

    it "starts a rollback once and claims positions clipped to the total" do
      created, meta = adapter.start_map_rollback("p1:m", "P", total: 5, batch_size: 2, step_name: "m",
                                                              reactor_class_info: { "type" => "class", "name" => "E" })
      again, = adapter.start_map_rollback("p1:m", "P", total: 9, batch_size: 9, step_name: "m",
                                                       reactor_class_info: {})

      expect([created, again]).to eq([true, false])
      expect(meta).to include("total" => 5, "batch_size" => 2,
                              "reactor_class_info" => { "type" => "class", "name" => "E" })
      expect(adapter.retrieve_map_rollback_metadata("p1:m", "P")["total"]).to eq(5)
      expect(adapter.claim_map_rollback_positions("p1:m", "P", 2)).to eq(0...2)
      expect(adapter.claim_map_rollback_positions("p1:m", "P", 2)).to eq(2...4)
      expect(adapter.claim_map_rollback_positions("p1:m", "P", 2)).to eq(4...5)
      expect(adapter.claim_map_rollback_positions("p1:m", "P", 2).to_a).to be_empty
      expect(adapter.retrieve_map_rollback_offset("p1:m", "P")).to eq(8)
    end

    it "stores outcomes first-wins and summarizes them" do
      adapter.start_map_rollback("p1:m", "P", total: 3, batch_size: 3, step_name: "m", reactor_class_info: {})
      expect(adapter.store_map_rollback_outcome("p1:m", "P", 0, { "index" => 2, "outcome" => "failed" })).to be(true)
      expect(adapter.store_map_rollback_outcome("p1:m", "P", 0, { "index" => 2, "outcome" => "undone" })).to be(false)
      adapter.store_map_rollback_outcome("p1:m", "P", 1, { "index" => 1, "outcome" => "undone", "failures" => [] })
      adapter.store_map_rollback_outcome("p1:m", "P", 2, { "index" => nil, "outcome" => "context_unavailable" })

      outcomes = []
      adapter.each_map_rollback_outcome("p1:m", "P") { |position, outcome| outcomes << [position, outcome["outcome"]] }
      expect(outcomes).to contain_exactly([0, "failed"], [1, "undone"], [2, "context_unavailable"])
      expect(adapter.count_map_rollback_outcomes("p1:m", "P")).to eq(3)
      expect(adapter.stored_map_rollback_positions("p1:m", "P")).to contain_exactly(0, 1, 2)
      expect(adapter.map_rollback_outcome_stored?("p1:m", "P", 1)).to be(true)
      expect(adapter.map_rollback_outcome_stored?("p1:m", "P", 7)).to be(false)
      expect(adapter.map_rollback_indexes_seen("p1:m", "P", [0, 1, 2])).to eq([false, true, true])
      expect(adapter.map_rollback_summary("p1:m", "P")).to eq(total: 3, settled: 3, outstanding: 0, failed: 2)
    end

    it "gates the owner signal on the hand-off, and claims it once" do
      expect(adapter.map_rollback_handed_off?("p1:m", "P")).to be(false)
      adapter.mark_map_rollback_handed_off("p1:m", "P")
      expect(adapter.map_rollback_handed_off?("p1:m", "P")).to be(true)
      expect(adapter.claim_map_rollback_signal("p1:m", "P")).to be(true)
      expect(adapter.claim_map_rollback_signal("p1:m", "P")).to be(false)
    end

    it "lists started rollbacks for the sweeper, and scan_maps skips them" do
      adapter.initialize_map_operation("p1:m", 5, "P", reactor_class_info: {})
      adapter.start_map_rollback("p1:m", "P", total: 5, batch_size: 2, step_name: "m", reactor_class_info: {})

      expect(adapter.scan_map_rollbacks(count: 10)).to contain_exactly(
        a_hash_including("map_id" => "p1:m", "parent_reactor_class_name" => "P", "total" => 5)
      )
      expect(adapter.scan_maps(count: 10).map { |meta| meta["map_id"] }).to eq(["p1:m"])
      expect(adapter.map_rollback_summary("p2:m", "P")).to be_nil
    end
  end

  describe "interrupt resumes" do
    it "claims once per interrupt and returns only claimed payloads" do
      expect(adapter.claim_interrupt_resume("ctx-1", klass, "approve", "{\"ok\":true}")).to be(true)
      expect(adapter.claim_interrupt_resume("ctx-1", klass, "approve", "{\"ok\":false}")).to be(false)

      expect(adapter.retrieve_interrupt_resumes("ctx-1", klass, %w[approve review]))
        .to eq("approve" => "{\"ok\":true}")
    end

    it "counts attempts atomically, returning the new value" do
      expect(adapter.increment_interrupt_attempts("ctx-1", klass, "approve")).to eq(1)
      expect(adapter.increment_interrupt_attempts("ctx-1", klass, "approve")).to eq(2)
    end
  end

  describe "idempotency keys" do
    it "is first-wins per reactor class" do
      expect(adapter.claim_idempotency_key("charge-7", "ctx-1", klass)).to be_nil
      expect(adapter.claim_idempotency_key("charge-7", "ctx-2", klass)).to eq("ctx-1")
      expect(adapter.claim_idempotency_key("charge-7", "ctx-3", "Other")).to be_nil
    end
  end

  describe "locks" do
    it "is re-entrant for its owner and refuses everyone else" do
      expect(adapter.lock_acquire("lock:k", "me", 60)).to be(true)
      expect(adapter.lock_acquire("lock:k", "me", 60)).to be(true)
      expect(adapter.lock_acquire("lock:k", "you", 60)).to be(false)
      expect(adapter.lock_info("lock:k")).to eq(owner: "me", count: 2)
      expect(adapter.lock_held?("k")).to be(true)

      expect(adapter.lock_release("lock:k", "you")).to be(false)
      expect(adapter.lock_release("lock:k", "me")).to be(true)
      expect(adapter.lock_held?("k")).to be(true)
      expect(adapter.lock_release("lock:k", "me")).to be(true)
      expect(adapter.lock_held?("k")).to be(false)
      expect(adapter.lock_info("lock:k")).to be_nil
      expect(adapter.lock_ttl("lock:k")).to eq(-2)
    end

    it "extends only for its owner, and expires after its ttl" do
      adapter.lock_acquire("lock:k", "me", 1)

      expect(adapter.lock_extend("lock:k", "you", 60)).to be(false)
      expect(adapter.lock_ttl("lock:k")).to be_between(0, 1)
      sleep 1.2
      expect(adapter.lock_held?("k")).to be(false)
      expect(adapter.lock_acquire("lock:k", "you", 60)).to be(true)
      expect(adapter.lock_extend("lock:k", "you", 120)).to be(true)
      expect(adapter.lock_ttl("lock:k")).to be_within(2).of(120)
    end
  end

  describe "semaphores" do
    before { adapter.semaphore_init("semaphore:s", 2) }

    it "initializes once and enforces its limit" do
      expect(adapter.semaphore_init("semaphore:s", 5)).to be(false)
      expect(adapter.semaphore_exists?("semaphore:s")).to be(true)

      t1 = adapter.semaphore_acquire("semaphore:s")
      t2 = adapter.semaphore_acquire("semaphore:s")
      expect([t1, t2]).to all(be_a(String))
      expect(adapter.semaphore_acquire("semaphore:s")).to be_nil
      expect(adapter.semaphore_held("semaphore:s", t1)).to be(true)
      expect(adapter.semaphore_state("s")).to eq(available: 0, held: 2, limit: 2)
    end

    it "refuses a double release and a token it never issued" do
      token = adapter.semaphore_acquire("semaphore:s")

      expect(adapter.semaphore_release("semaphore:s", token, 2)).to be(true)
      expect(adapter.semaphore_release("semaphore:s", token, 2)).to be(false)
      expect(adapter.semaphore_release("semaphore:s", "forged", 2)).to be(false)
      expect(adapter.semaphore_state("s")).to eq(available: 2, held: 0, limit: 2)
    end

    # Same-thread only: the Redis adapter's one shared connection blocks every
    # other thread for the whole BLPOP, so a cross-thread release can't land
    # mid-wait there.
    it "takes an available token at once, and gives up after its timeout" do
      expect(adapter.semaphore_acquire("semaphore:s", timeout: 1)).to be_a(String)
      adapter.semaphore_acquire("semaphore:s")

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(adapter.semaphore_acquire("semaphore:s", timeout: 0.3)).to be_nil
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be >= 0.25
    end

    it "resets" do
      adapter.semaphore_reset("semaphore:s")

      expect(adapter.semaphore_exists?("semaphore:s")).to be(false)
    end
  end

  describe "rate limits" do
    let(:now) { Time.now.to_i }
    let(:minute_key) { "rate:api:60:#{now / 60}" }
    let(:hour_key) { "rate:api:3600:#{now / 3600}" }

    it "allows or denies all windows together" do
      args = [now, 60, 2, 60, 3600, 1, 3600]

      expect(adapter.rate_limit_check_and_increment([minute_key, hour_key], args)).to eq([1, 0, 0])
      allowed, retry_after, failed_index = adapter.rate_limit_check_and_increment([minute_key, hour_key], args)

      expect([allowed, failed_index]).to eq([0, 2])
      expect(retry_after).to be_between(1, 3600)
      expect(adapter.rate_limit_count("api", 60, now: now)).to eq(1) # the denied call incremented nothing
      expect(adapter.rate_limit_ttl("api", 60, now: now)).to be_between(1, 60)
    end
  end

  describe "periods" do
    it "marks and sees a bucket" do
      key = RubyReactor::Period.key("report", :day)
      expect(adapter.period_seen?(key)).to be(false)

      adapter.period_mark(key, RubyReactor::Period.ttl_seconds(:day))

      expect(adapter.period_seen?(key)).to be(true)
      expect(adapter.period_marker?("report", :day)).to be(true)
    end

    it "accepts the claiming execution" do
      key = RubyReactor::Period.key("report", :year)

      adapter.period_mark(key, RubyReactor::Period.ttl_seconds(:year), context_id: "ctx-1")

      expect(adapter.period_seen?(key)).to be(true)
    end

    # 011 US5.
    it "names the execution that claimed the bucket" do
      adapter.period_mark(RubyReactor::Period.key("report", :year), 60, context_id: "ctx-1")
      adapter.period_mark(RubyReactor::Period.key("legacy", :year), 60)

      expect(adapter.period_marker_info("report", :year)).to include(context_id: "ctx-1")
      expect(adapter.period_marker_info("legacy", :year)).to include(context_id: nil)
      expect(adapter.period_marker_info("never", :year)).to be_nil
    end

    it "keeps the first claim forever, with its time", :active_record_only do
      jan = Time.utc(2026, 1, 1, 0, 5)
      dec = Time.utc(2026, 12, 31, 23, 55)
      expect(RubyReactor::Period.key("annual", :year,
                                     now: jan)).to eq(RubyReactor::Period.key("annual", :year, now: dec))

      adapter.period_mark(RubyReactor::Period.key("annual", :year, now: jan), 60, context_id: "first")
      adapter.period_mark(RubyReactor::Period.key("annual", :year, now: dec), 60, context_id: "second")

      expect(adapter.period_marker?("annual", :year, now: dec)).to be(true)
      expect(adapter.period_marker_info("annual", :year,
                                        now: dec)).to match(context_id: "first", claimed_at: be_a(Time))
      expect(adapter.period_ttl("annual", :year, now: dec)).to eq(-1)
    end
  end

  # 011 US4, R-11/R-18: the dashboard's filtered listing over all history.
  describe "query_executions", :active_record_only do
    let(:models) { RubyReactor::Storage::ActiveRecordAdapter }
    let!(:ids) do
      {
        a: store(QueryContractSpec::Charge, { user_id: 100 }, :completed),
        b: store(QueryContractSpec::Charge, { user_id: 200 }, :failed),
        c: store(QueryContractSpec::Refund, { user_id: 100 }, :paused),
        d: store(QueryContractSpec::Charge, { user_id: 100, card_token: "tok", meta: { plan: "pro" },
                                              note: "n" * 300 }, :completed)
      }
    end

    def store(klass, inputs, status)
      context = RubyReactor::Context.new(inputs, klass)
      context.status = status
      adapter.store_context(context.context_id, RubyReactor::ContextSerializer.serialize(context), klass.name)
      context.context_id
    end

    def query(**filters)
      adapter.query_executions(filters: filters, cursor: "0", count: 50)[:reactors].map do |r|
        r[:id]
      end
    end

    it "filters by input value, class and status, alone and combined" do
      expect(query(inputs: { "user_id" => "100" })).to contain_exactly(ids[:a], ids[:c], ids[:d])
      expect(query(reactor_class: QueryContractSpec::Charge.name, inputs: { "user_id" => "100" }))
        .to contain_exactly(ids[:a], ids[:d])
      expect(query(status: "completed")).to contain_exactly(ids[:a], ids[:d])
      expect(query(reactor_class: QueryContractSpec::Refund.name)).to eq([ids[:c]])
      expect(query(status: "failed", inputs: { "user_id" => "100" })).to be_empty
    end

    it "filters by start time, newest first" do
      times = { a: 3.hours.ago, b: 2.hours.ago, c: 1.hour.ago, d: 10.minutes.ago }
      times.each { |key, time| models::Execution.where(id: ids[key]).update_all(started_at: time) }

      expect(query(from: 150.minutes.ago)).to eq([ids[:d], ids[:c], ids[:b]])
      expect(query(from: 150.minutes.ago, to: 30.minutes.ago)).to eq([ids[:c], ids[:b]])
    end

    it "pages through every match exactly once" do
      first = adapter.query_executions(filters: {}, cursor: "0", count: 3)
      second = adapter.query_executions(filters: {}, cursor: first[:cursor], count: 3)

      expect(first[:reactors].size).to eq(3)
      expect((first[:reactors] + second[:reactors]).map { |r| r[:id] }).to match_array(ids.values)
      expect(second[:cursor]).to eq("0")
    end

    it "never matches redacted, non-scalar or overlong inputs" do
      expect(query(inputs: { "card_token" => "tok" })).to be_empty
      expect(query(inputs: { "note" => "n" * 300 })).to be_empty
      expect(models::ExecutionInput.where(execution_id: ids[:d]).pluck(:name)).to eq(["user_id"])
    end

    it "keeps executions older than context_ttl" do
      models::Execution.update_all(updated_at: Time.current - RubyReactor.configuration.context_ttl - 60)

      expect(query(inputs: { "user_id" => "200" })).to eq([ids[:b]])
    end
  end

  describe "completion signals" do
    it "blocks a subscriber until its thread is killed, and publishing never raises" do
      subscriber = Thread.new { adapter.subscribe("contract:ch") { false } }
      sleep 0.2

      expect(subscriber).to be_alive
      expect { adapter.publish("contract:ch", "done") }.not_to raise_error
      subscriber.kill
      subscriber.join(1)
    end
  end
end
