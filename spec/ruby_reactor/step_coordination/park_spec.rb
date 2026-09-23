# frozen_string_literal: true

require "spec_helper"

# US2 (005 quickstart R2, R4, R6): a park at any nesting depth keeps every
# level's own lock and semaphore, charges reactor-level quotas once, and a
# background-result wait inside a composed child parks instead of failing the
# parent. Every park is driven through the real `Worker#perform`, one job at a
# time (`Sidekiq::Testing.fake!`).
RSpec.describe "parks at any depth", :step_coordination do
  let(:run_id) { step_coord_run_id }
  let(:account_id) { SecureRandom.random_number(10**9) }
  let(:worker_class) { RubyReactor::Adapters::Sidekiq::Worker }
  let(:events) { [] }

  around do |example|
    original = RubyReactor.configuration.middlewares
    recorded = events
    RubyReactor.configuration.middlewares = [
      Class.new do
        define_method(:on) { |event, *args| recorded << [event, *args.first(1)] }
      end.new
    ]
    example.run
  ensure
    RubyReactor.configuration.middlewares = original
  end

  def hold(key)
    lock = RubyReactor::Lock.new(key, owner: "external-holder", ttl: 30, auto_extend: false)
    lock.acquire
    lock
  end

  def perform_once
    job = worker_class.jobs.last
    worker_class.jobs.clear
    worker_class.new.perform(*job["args"])
  end

  def status_of(reactor, dispatch)
    reactor.find(dispatch.execution_id).context.status.to_s
  end

  def events_named(name, step = nil)
    events.select { |event, arg| event == name && (step.nil? || arg.to_s == step.to_s) }
  end

  describe "a parent rate limit across a composed park (R2)" do
    it "is charged once per execution" do
      holder = hold("park:acct:#{account_id}")
      dispatch = ParkRateParentReactor.run(run_id: run_id, account_id: account_id)

      perform_once
      expect(status_of(ParkRateParentReactor, dispatch)).not_to eq("failed")
      expect(worker_class.jobs.size).to eq(1)

      holder.release
      perform_once

      expect(status_of(ParkRateParentReactor, dispatch)).to eq("completed")
      expect("park:rl:#{run_id}").to have_rate_limit_count(1).for(:hour)
    end

    it "is charged once with no contention at all (control)" do
      dispatch = ParkRateParentReactor.run(run_id: run_id, account_id: account_id)
      perform_once

      expect(status_of(ParkRateParentReactor, dispatch)).to eq("completed")
      expect("park:rl:#{run_id}").to have_rate_limit_count(1).for(:hour)
    end

    it "emits :snooze_step for the parked step, never :failed_step" do
      holder = hold("park:acct:#{account_id}")
      ParkRateParentReactor.run(run_id: run_id, account_id: account_id)
      perform_once
      holder.release
      perform_once

      expect(events_named(:snooze_step, :charge).size).to eq(1)
      expect(events_named(:failed_step)).to be_empty
    end
  end

  describe "a parent lock across a composed park (R4)" do
    it "stays held through the park and is acquired exactly once" do
      parent_key = "park:parent:#{run_id}"
      holder = hold("park:acct:#{account_id}")
      dispatch = ParkLockParentReactor.run(run_id: run_id, account_id: account_id)

      perform_once
      expect(parent_key).to be_locked

      holder.release
      perform_once

      expect(status_of(ParkLockParentReactor, dispatch)).to eq("completed")
      expect(parent_key).not_to be_locked
      expect(events_named(:lock_acquired, parent_key).size).to eq(1)
    end

    it "hands the parent lock back when the contention ceiling ends the execution (US2-6)" do
      RubyReactor.configuration.lock_snooze_max_attempts = 1
      holder = hold("park:acct:#{account_id}")
      dispatch = ParkLockParentReactor.run(run_id: run_id, account_id: account_id)

      perform_once
      perform_once

      expect(status_of(ParkLockParentReactor, dispatch)).to eq("failed")
      expect("park:parent:#{run_id}").not_to be_locked
    ensure
      holder&.release
    end

    it "re-acquires a parent lock that lapsed during the gap, still charging the rate limit once (US2-5)" do
      holder = hold("park:acct:#{account_id}")
      dispatch = ParkShortTtlParentReactor.run(run_id: run_id, account_id: account_id)

      perform_once
      holder.release
      sleep 1.2 # the parked lock's ttl (1 s) runs out with no extender
      perform_once

      expect(status_of(ParkShortTtlParentReactor, dispatch)).to eq("completed")
      expect("park:short:#{run_id}").not_to be_locked
      expect("park:short_rl:#{run_id}").to have_rate_limit_count(1).for(:hour)
    end
  end

  describe "a park two composition levels down" do
    it "keeps the middle level's lock through the gap and charges its rate limit once" do
      holder = hold("park:acct:#{account_id}")
      dispatch = ParkGrandParentReactor.run(run_id: run_id, account_id: account_id)

      perform_once
      expect("park:middle:#{run_id}").to be_locked

      holder.release
      perform_once

      expect(status_of(ParkGrandParentReactor, dispatch)).to eq("completed")
      expect("park:middle:#{run_id}").not_to be_locked
      expect("park:middle_rl:#{run_id}").to have_rate_limit_count(1).for(:hour)
    end
  end

  describe "a map element that contends (US2-7)" do
    it "parks the element and completes it after the key is free" do
      holder = hold("park:acct:#{account_id}")
      reactor = ParkMapReactor.new
      reactor.run(account_ids: [account_id])
      map_worker = RubyReactor::Adapters::Sidekiq::MapElementWorker

      job = map_worker.jobs.last
      map_worker.jobs.clear
      map_worker.new.perform(*job["args"])
      expect(map_worker.jobs.size).to eq(1)

      holder.release
      map_worker.drain
      RubyReactor::Adapters::Sidekiq::MapCollectorWorker.drain

      stored = RubyReactor.configuration.storage_adapter.retrieve_context(reactor.context.context_id, "ParkMapReactor")
      enumerator = RubyReactor::ContextSerializer.deserialize_value(stored["intermediate_results"]["charges"])
      expect(enumerator.to_a.map(&:value)).to eq([account_id])
    end
  end

  describe "a background-result wait inside a composed child (R6, F10)" do
    it "parks the execution, keeping the child's lock, instead of failing the parent" do
      dispatch = ParkAsyncReaderParent.run(run_id: run_id)

      perform_once
      expect(status_of(ParkAsyncReaderParent, dispatch)).not_to eq("failed")
      expect(worker_class.jobs.size).to eq(1)
      expect("park:reader:#{run_id}").to be_locked

      RubyReactor::Adapters::Sidekiq::StepWorker.drain
      perform_once

      result = ParkAsyncReaderParent.find(dispatch.execution_id)
      expect(result.context.status.to_s).to eq("completed")
      expect(result.context.get_result(:child)).to eq("fetched:#{run_id}")
      expect("park:reader:#{run_id}").not_to be_locked
      expect(events_named(:failed_step)).to be_empty
    end
  end

  # US4 (005 quickstart P4): a parked `async_step` keeps its ordering position
  # and its waiting marker on its OWN Step Result Record. Its worker never
  # writes the parent's root blob on a park, so a newer parent checkpoint is
  # never overwritten. A real Sidekiq worker runs both the parent and the unit.
  describe "async_step park state (US4)" do
    include_context "with a real async worker", :sidekiq

    let(:storage) { RubyReactor.configuration.storage_adapter }

    def eventually(what, timeout: 40)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until (value = yield)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise "timed out after #{timeout}s waiting for #{what}" if now > deadline

        sleep 0.2
      end
      value
    end

    def unit_record(execution_id)
      storage.retrieve_step_result(execution_id, :ordered, "AspReactor")
    end

    it "keeps the unit's position and waiting marker on its record and never rewrites the parent" do
      holder = RubyReactor::Lock.new("asp:lock:#{run_id}", owner: "external-holder", ttl: 120, auto_extend: false)
      holder.acquire
      id = AspReactor.run(run_id: run_id).execution_id

      eventually("the parent to complete") { AspReactor.find(id).context.status.to_s == "completed" }
      eventually("the first park") { unit_record(id)&.dig("contention_attempts").to_i >= 1 }

      # A newer parent checkpoint, written while the unit is parked.
      context = RubyReactor::ContextSerializer.deserialize_hash(storage.retrieve_context(id, "AspReactor"))
      context.private_data[:parent_checkpoint] = "newer"
      storage.store_context(id, RubyReactor::ContextSerializer.serialize(context), "AspReactor")
      checkpoint = storage.retrieve_context(id, "AspReactor")

      eventually("a second park") { unit_record(id)["contention_attempts"].to_i >= 2 }

      expect(storage.retrieve_context(id, "AspReactor")).to eq(checkpoint)
      record = unit_record(id)
      expect(record["ordered_lock"]).to include("key" => "asp:seq:#{run_id}", "nonce" => 1)
      expect(record["waiting"]).to include("step" => "ordered", "primitive" => "lock", "key" => "asp:lock:#{run_id}")
      # The redelivery re-read its position instead of taking a fresh one.
      expect("asp:seq:#{run_id}").to have_ordered_lock_next(1)

      parent = AspReactor.find(id).context
      coordination = RubyReactor::Web::CoordinationSerializer.build(
        AspReactor, inputs: parent.inputs, context_id: id,
                    execution_trace: parent.execution_trace, private_data: parent.private_data
      )
      expect(coordination[:waiting]).to include(step: "ordered", key: "asp:lock:#{run_id}")

      holder.release
      eventually("the unit to complete") { unit_record(id)["status"] == "completed" }

      expect(unit_record(id)).not_to include("ordered_lock", "waiting")
      expect(redis.lrange(AspSupport.log_key(run_id), 0, -1)).to contain_exactly("progress", "ordered")
      expect("asp:seq:#{run_id}").to be_ordered_lock_drained
      expect(AspReactor.find(id).context.private_data[:parent_checkpoint]).to eq("newer")
    ensure
      holder&.release
    end
  end

  describe "synchronous contention" do
    it "records no park markers — there is no queue to park into, the step just fails" do
      account_id = unique_account_id
      key = "acct:#{account_id}"
      holder = RubyReactor::Lock.new(key, owner: "external-holder", ttl: 5, wait: 0, auto_extend: true)
      holder.acquire

      context = RubyReactor::Context.new(
        { run_id: step_coord_run_id, account_id: account_id }, WaitZeroLockedChargeReactor
      )
      result = RubyReactor::Executor.new(WaitZeroLockedChargeReactor, {}, context).execute

      expect(result).to be_a(RubyReactor::Failure)
      expect(context.execution_trace.map { |e| e[:type].to_s }).not_to include("contention_park")
      expect(context.private_data[:step_contention]).to be_nil
    ensure
      holder&.release
    end
  end

  describe "an async_step parked on contention" do
    it "is not re-dispatched by StepSweeper while its redelivery is still due" do
      account_id = unique_account_id
      holder = RubyReactor::Semaphore.new("sweep_park_sem:#{account_id}", limit: 1)
      holder.acquire

      dispatch = SweepParkReactor.run(account_id: account_id)
      # Perform the unit exactly once: it parks and reschedules itself, which
      # releases the liveness lock and leaves the record at "dispatched".
      job = RubyReactor::Adapters::Sidekiq::StepWorker.jobs.last
      RubyReactor::Adapters::Sidekiq::StepWorker.jobs.clear
      RubyReactor::Adapters::Sidekiq::StepWorker.new.perform(*job["args"])

      # A re-dispatch here would run the body a second time when the parked
      # redelivery fires — the two are sequential, so the liveness lock never
      # sees them collide.
      expect(RubyReactor::StepSweeper.run_once).to eq(0)

      record = RubyReactor.configuration.storage_adapter.retrieve_step_result(
        dispatch.execution_id, :charge, "SweepParkReactor"
      )
      expect(record["status"]).to eq("dispatched")
      expect(Time.iso8601(record["parked_until"])).to be > Time.now
    ensure
      holder&.release
    end
  end

  describe "a contention park escalated to a terminal failure by the ceiling" do
    it "hands back the reactor-level hold instead of leaving it parked until its TTL" do
      config = RubyReactor.configuration
      original_max = config.lock_snooze_max_attempts
      config.lock_snooze_max_attempts = 1
      account_id = unique_account_id
      holder = RubyReactor::Lock.new("ceiling_step:#{account_id}", owner: "external-holder", ttl: 60, wait: 0,
                                                                   auto_extend: true)
      holder.acquire

      context = RubyReactor::Context.new({ account_id: account_id }, CeilingReactor)
      context.inline_async_execution = true

      expect { RubyReactor::Executor.new(CeilingReactor, {}, context).execute }
        .to raise_error(RubyReactor::Error::StepContentionPark)
      expect(context.private_data[:parked_primitives]).to eq({ lock: true })

      # A fresh executor, as the redelivered job builds: it re-adopts the
      # parked hold, then the ceiling turns this park terminal.
      expect(RubyReactor::Executor.new(CeilingReactor, {}, context).resume_execution)
        .to be_a(RubyReactor::Failure)
      expect(context.private_data[:parked_primitives]).to be_nil
      # Nothing is coming back for it, so the reactor's own key must be free.
      probe = RubyReactor::Lock.new("ceiling_reactor:#{account_id}", owner: "probe", ttl: 5, wait: 0,
                                                                     auto_extend: false)
      expect { probe.acquire }.not_to raise_error
      probe.release
    ensure
      holder&.release
      config.lock_snooze_max_attempts = original_max
    end
  end

  describe "an async_step inside a composed child" do
    it "writes its Step Result Record under the child's namespace, where the reader looks" do
      account_id = unique_account_id

      ComposedAsyncParentReactor.run(account_id: account_id)
      job = RubyReactor::Adapters::Sidekiq::StepWorker.jobs.last
      step_context_id = job["args"].first["step_context_id"] || job["args"].first[:step_context_id]
      perform_last_step_job

      storage = RubyReactor.configuration.storage_adapter
      record = storage.retrieve_step_result(step_context_id, :charge, "ComposedAsyncChildReactor")
      expect(record["status"]).to eq("completed")
      expect(record["success"]).to be(true)
    end
  end

  describe "a redelivery of an async_step unit that already finished" do
    before { ROUND4_COUNTS.clear }

    it "is dropped instead of running the body a second time" do
      Round4DuplicateReactor.run(account_id: unique_account_id)
      job = RubyReactor::Adapters::Sidekiq::StepWorker.jobs.last
      RubyReactor::Adapters::Sidekiq::StepWorker.jobs.clear

      2.times { RubyReactor::Adapters::Sidekiq::StepWorker.new.perform(*job["args"]) }

      expect(ROUND4_COUNTS[:duplicate_body]).to eq(1)
    end
  end
end
