# frozen_string_literal: true

require "spec_helper"

# 010 US2 (FR-005–FR-007, P-1): a run in the caller's process hands off at a
# fan-out map, and the Worker its completion enqueues starts BEFORE the
# caller's final save. The caller holds the run's lock until that save (R-01),
# and the Worker locks before it loads (R-02), so the Worker never runs on, or
# saves over, anything older than the caller's final state.
module CallerSaveRaceSpec
  class << self
    attr_accessor :on_hand_off
  end

  # Fires inside the caller's executor, after the map step returned its
  # hand-off and before the run's final save.
  class Probe < RubyReactor::Middleware
    def on_complete_step(step_name, result, _context)
      return unless step_name.to_sym == :m && result.is_a?(RubyReactor::DispatchResult)

      CallerSaveRaceSpec.on_hand_off&.call
    end
  end

  class Run < RollbackRecorder::Reactor
    middleware Probe
    input :items
    recording_step :a
    map :m, MapRollbackFixtures::ElemOk do
      source input(:items)
      argument :i, element(:m)
      fan_out(batch_size: 2)
    end
    recording_step :b, after: :m
    recording_step :c, after: :b
  end

  # The map's source is the resume payload, so `continue` drives the run
  # into the hand-off from the caller's process.
  class Resumed < RollbackRecorder::Reactor
    middleware Probe
    recording_step :a
    interrupt(:go) { wait_for :a }
    map :m, MapRollbackFixtures::ElemOk do
      source result(:go)
      argument :i, element(:m)
      fan_out(batch_size: 2)
    end
    recording_step :b, after: :m
    recording_step :c, after: :b
  end
end

RSpec.describe "A caller's final save vs the Worker its hand-off enqueues (010 US2)" do
  include RubyReactor::RSpec::SidekiqHelpers

  let(:storage) { RubyReactor.configuration.storage_adapter }
  let(:observed) { { worker_runs: 0, worker_writes: [], snoozed: false } }

  before do
    RollbackRecorder.reset!
    Sidekiq::Worker.clear_all
    stub_const("RubyReactor::Worker::CONTEXT_LOCK_WAIT", 0.1)
    in_worker = false
    seen = observed
    allow(storage).to receive(:store_context).and_wrap_original do |m, *args|
      seen[:worker_writes] << args.first if in_worker
      m.call(*args)
    end
    # Perform queued jobs one at a time until the owner's Worker has run once:
    # the elements, the collector, then the resume they enqueue.
    CallerSaveRaceSpec.on_hand_off = lambda do
      50.times do
        job = QueueProbe.next_job
        break unless job

        owner = job.worker_class == RubyReactor::Adapters::Sidekiq::Worker
        in_worker = owner
        job.perform!
        in_worker = false
        next unless owner

        seen[:worker_runs] += 1
        seen[:snoozed] = RubyReactor::Adapters::Sidekiq::Worker.jobs.any?
        break
      end
    end
  end

  after { CallerSaveRaceSpec.on_hand_off = nil }

  def expect_finished_once(id, klass)
    drain_async_jobs
    expect(klass.find(id).context.status.to_s).to eq("completed")
    expect(RollbackRecorder.log.count("run:b")).to eq(1)
    expect(RollbackRecorder.log.count("run:c")).to eq(1)
  end

  it "keeps the Worker off the run until the caller's final save (Reactor.run)" do
    result = CallerSaveRaceSpec::Run.run(items: [1, 2, 3])
    id = result.execution_id

    expect(result).to be_a(RubyReactor::DispatchResult)
    expect(observed[:worker_runs]).to eq(1)
    expect(observed[:worker_writes]).not_to include(id)
    expect(observed[:snoozed]).to be(true)
    expect_finished_once(id, CallerSaveRaceSpec::Run)
  end

  it "keeps the Worker off the run until the caller's final save (inline continue)" do
    reactor = CallerSaveRaceSpec::Resumed.new
    expect(reactor.run({})).to be_a(RubyReactor::InterruptResult)
    id = reactor.context.context_id

    result = CallerSaveRaceSpec::Resumed.continue(id: id, payload: [1, 2, 3], step_name: :go)

    expect(result).to be_a(RubyReactor::DispatchResult)
    expect(observed[:worker_runs]).to eq(1)
    expect(observed[:worker_writes]).not_to include(id)
    expect_finished_once(id, CallerSaveRaceSpec::Resumed)
  end

  it "behaves as before when the caller finishes first (FR-007)" do
    CallerSaveRaceSpec.on_hand_off = nil

    result = CallerSaveRaceSpec::Run.run(items: [1, 2, 3])

    expect(result).to be_a(RubyReactor::DispatchResult)
    expect_finished_once(result.execution_id, CallerSaveRaceSpec::Run)
  end
end
