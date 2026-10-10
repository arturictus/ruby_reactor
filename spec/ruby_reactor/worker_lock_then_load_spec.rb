# frozen_string_literal: true

require "spec_helper"

# 010 R-02 / R-06 / J-2: a Worker takes the run's liveness lock BEFORE it
# reads the run, so it always sees the last save of whoever held it, and it
# only resumes a run whose status asks for it.
module WorkerLtlSpec
  class TwoSteps < RollbackRecorder::Reactor
    recording_step :a
    recording_step :b, after: :a
  end
end

RSpec.describe "Worker: lock, then load (010 R-02, R-06)" do
  let(:storage) { RubyReactor.configuration.storage_adapter }
  let(:worker_class) { RubyReactor::Adapters::Sidekiq::Worker }
  let(:klass_name) { "WorkerLtlSpec::TwoSteps" }

  before do
    RollbackRecorder.reset!
    Sidekiq::Worker.clear_all
  end

  def store(status:, current_step: nil)
    context = RubyReactor::Context.new({}, WorkerLtlSpec::TwoSteps)
    context.status = status
    context.current_step = current_step
    storage.store_context(context.context_id, RubyReactor::ContextSerializer.serialize(context), klass_name)
    context.context_id
  end

  def lock_held?(id)
    storage.lock_held?("async:#{id}")
  end

  it "takes the async: lock before reading the context" do
    id = store(status: :running)
    calls = []
    allow_any_instance_of(RubyReactor::Lock).to receive(:acquire).and_wrap_original do |m, *args|
      calls << [:acquire, m.receiver.key]
      m.call(*args)
    end
    allow(storage).to receive(:retrieve_context).and_wrap_original do |m, *args|
      calls << [:retrieve, args.first]
      m.call(*args)
    end

    worker_class.new.perform(id, klass_name)

    acquire = calls.index([:acquire, "lock:async:#{id}"])
    retrieve = calls.index([:retrieve, id])
    expect(acquire).not_to be_nil
    expect(retrieve).not_to be_nil
    expect(acquire).to be < retrieve
    expect(RollbackRecorder.log).to eq(%w[run:a run:b])
    expect(lock_held?(id)).to be(false)
  end

  it "snoozes without reading or writing while another owner holds the lock" do
    stub_const("RubyReactor::Worker::CONTEXT_LOCK_WAIT", 0.2)
    id = store(status: :running)
    other = RubyReactor::Lock.new("async:#{id}", owner: "other", ttl: 30, auto_extend: false)
    other.acquire
    allow(storage).to receive(:retrieve_context)
    allow(storage).to receive(:store_context)
    worker = worker_class.new
    allow(worker).to receive(:escalate_snooze)

    worker.perform(id, klass_name, 50) # above lock_snooze_max_attempts: still uncapped

    expect(storage).not_to have_received(:retrieve_context)
    expect(storage).not_to have_received(:store_context)
    expect(worker).not_to have_received(:escalate_snooze)

    jobs = worker_class.jobs
    expect(jobs.size).to eq(1)
    expect(jobs.first["args"]).to eq([id, klass_name, 51])
  ensure
    other&.release
  end

  %i[completed failed cancelled aborted halted].each do |status|
    it "does not resume a #{status} run, and releases the lock" do
      id = store(status: status)
      expect_any_instance_of(RubyReactor::Executor).not_to receive(:resume_execution)

      worker_class.new.perform(id, klass_name)

      expect(RollbackRecorder.log).to be_empty
      expect(lock_held?(id)).to be(false)
    end
  end

  it "leaves a paused run without claimed payloads untouched" do
    reactor = ResumeFixtures::PlainApproval.new
    expect(reactor.run({})).to be_a(RubyReactor::InterruptResult)
    id = reactor.context.context_id
    before = storage.retrieve_context(id, "ResumeFixtures::PlainApproval")
    expect_any_instance_of(RubyReactor::Executor).not_to receive(:resume_execution)

    worker_class.new.perform(id, "ResumeFixtures::PlainApproval")

    expect(storage.retrieve_context(id, "ResumeFixtures::PlainApproval")).to eq(before)
    expect(lock_held?(id)).to be(false)
  end

  it "releases the lock after a deserialization failure" do
    id = SecureRandom.uuid
    storage.store_context(id, JSON.generate("schema_version" => "999", "context_id" => id,
                                            "reactor_class" => klass_name, "status" => "running"), klass_name)

    worker_class.new.perform(id, klass_name)

    expect(lock_held?(id)).to be(false)
    expect(storage.retrieve_context(id, klass_name)["status"]).to eq("failed")
  end

  it "takes no async: lock in inline job-testing mode" do
    id = store(status: :running)
    keys = []
    allow_any_instance_of(RubyReactor::Lock).to receive(:acquire).and_wrap_original do |m, *args|
      keys << m.receiver.key
      m.call(*args)
    end

    Sidekiq::Testing.inline! { worker_class.new.perform(id, klass_name) }

    expect(keys).not_to include("lock:async:#{id}")
    expect(RollbackRecorder.log).to eq(%w[run:a run:b])
  end
end
