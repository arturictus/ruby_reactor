# frozen_string_literal: true

require "spec_helper"

# 009 US1: a fan-out map rolls back the way it ran — one job per started
# element, `batch_size` per throw — and the run resumes once every element has
# reported, ending with the Failure the same run with an inline map gives
# (contracts/rollback-protocol.md I-4, I-7).
module DistributedMapRollbackSpec
  ITEMS = (0...20).to_a

  {
    Later: [MapRollbackFixtures::ElemOk, { b_fails: true }],
    Atomic: [MapRollbackFixtures::Elem, {}],
    UndoFails: [MapRollbackFixtures::ElemUndoFails, { b_fails: true }],
    Completes: [MapRollbackFixtures::ElemOk, {}]
  }.each do |name, (element, options)|
    MapRollbackFixtures.parent(self, name, element, fan_out: true, batch_size: 5, **options)
    MapRollbackFixtures.parent(self, :"#{name}Inline", element, **options)
  end

  # Deletes the context row of the element at `index`, as if it expired.
  def self.expire_element(ctx, index)
    storage = RubyReactor.configuration.storage_adapter
    element = MapRollbackFixtures::ElemOk.name
    storage.retrieve_map_element_context_ids("#{ctx.context_id}:m", ctx.reactor_class.name).each do |id|
      data = storage.retrieve_context(id, element)
      metadata = RubyReactor::ContextSerializer.deserialize_value(data && data["map_metadata"]) || {}
      storage.delete_context(id, element) if RubyReactor::Utils::FetchIndifferent.call(metadata, :index) == index
    end
  end

  [true, false].each do |distributed|
    klass = Class.new(RollbackRecorder::Reactor) do
      input :items
      recording_step :a
      map :m, MapRollbackFixtures::ElemOk do
        source input(:items)
        argument :i, element(:m)
        fan_out(batch_size: 5) if distributed
      end
      recording_step(:b, after: :m) do
        run do |_inputs, ctx|
          DistributedMapRollbackSpec.expire_element(ctx, 3)
          RubyReactor.Failure("boom b")
        end
      end
    end
    const_set(distributed ? :Expires : :ExpiresInline, klass)
  end
end

RSpec.describe "distributed map rollback" do
  let(:storage) { RubyReactor.configuration.storage_adapter }
  let(:log) { RollbackRecorder.log }
  let(:items) { { items: DistributedMapRollbackSpec::ITEMS } }

  def drain
    RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs(max_iterations: 500)
  end

  def rollback_job?(job)
    QueueProbe.class_of(job).name.end_with?("MapElementRollbackWorker")
  end

  # Performs queued jobs one at a time until an element rollback job is queued.
  def perform_until_rollback_queued
    1000.times do
      return if QueueProbe.pending.any? { |job| rollback_job?(job) }

      (QueueProbe.next_job || raise("no rollback job was ever queued")).perform!
    end
  end

  # Drains one job at a time, yielding each before it runs.
  def drain_each
    while (job = QueueProbe.next_job)
      yield job
      job.perform!
    end
  end

  def fan_out_result(reactor, inputs = items)
    id = reactor.run(inputs).execution_id
    drain
    reactor.find(id)
  end

  def outcomes(reactor, id)
    all = []
    storage.each_map_rollback_outcome("#{id}:m", reactor.name) { |_, outcome| all << outcome }
    all
  end

  def shape(failure)
    [failure.error.to_s, failure.step_name.to_s,
     failure.rollback_failures.sort_by { |entry| entry[:element_index].to_i }]
  end

  for_each_async_backend do
    it "hands off as rolling_back, undoes every element once, then the steps before the map" do
      id = DistributedMapRollbackSpec::Later.run(items).execution_id
      perform_until_rollback_queued
      expect(DistributedMapRollbackSpec::Later.find(id).context.status.to_s).to eq("rolling_back")

      drain

      expect(DistributedMapRollbackSpec::Later.find(id).context.status.to_s).to eq("failed")
      DistributedMapRollbackSpec::ITEMS.each do |i|
        expect(log.count("undo:e.e2[#{i}]")).to eq(1)
        expect(log.count("undo:e.e1[#{i}]")).to eq(1)
      end
      expect(log.rindex { |event| event.start_with?("undo:e.") }).to be < log.index("undo:a")
    end

    it "ends with the inline map's Failure and undoes the same elements (the oracle)" do
      %i[Later UndoFails].each do |name|
        RollbackRecorder.reset!
        inline = DistributedMapRollbackSpec.const_get(:"#{name}Inline").run(items)
        inline_undone = log.grep(/\Aundo:e\./).to_set

        RollbackRecorder.reset!
        fan_out = fan_out_result(DistributedMapRollbackSpec.const_get(name)).result

        expect(shape(fan_out)).to eq(shape(inline))
        expect(log.grep(/\Aundo:e\./).to_set).to eq(inline_undone)
      end
    end

    it "gives every started element a job and undoes only the completed ones (atomic)" do
      performed = 0
      id = DistributedMapRollbackSpec::Atomic.run(items: DistributedMapRollbackSpec::ITEMS, fail_at: 7).execution_id
      drain_each { |job| performed += 1 if rollback_job?(job) }

      started = storage.count_map_element_context_ids("#{id}:m", DistributedMapRollbackSpec::Atomic.name)
      all = outcomes(DistributedMapRollbackSpec::Atomic, id)
      expect(performed).to eq(started)
      expect(all.size).to eq(started)
      expect(all.find { |outcome| outcome["index"] == 7 }["outcome"]).to eq("not_needed")
      expect(log.count("undo:e.e1[7]")).to eq(1) # its own rollback, never the map's
      expect(log.grep(/\Aundo:e\.e2\[7\]/)).to be_empty
      completed = log.grep(/\Arun:e\.e2\[(\d+)\]/) { Regexp.last_match(1).to_i } - [7]
      completed.each { |i| expect(log.count("undo:e.e2[#{i}]")).to eq(1) }
      expect(all.map { |outcome| outcome["index"] }).to all(be < started)
    end

    it "reports an element's undo failure with its map step and index, and still undoes the steps before" do
      inline = DistributedMapRollbackSpec::UndoFailsInline.run(items)
      RollbackRecorder.reset!

      result = fan_out_result(DistributedMapRollbackSpec::UndoFails).result

      entry = result.rollback_failures.find { |failure| failure[:element_index] == 1 }
      expect(entry).to include(step: :e1, kind: :undo, map_step: :m, element_index: 1)
      expect(entry).to eq(inline.rollback_failures.find { |failure| failure[:element_index] == 1 })
      expect(log).to include("undo:a")
    end

    it "enqueues at most batch_size rollback jobs per throw" do
      DistributedMapRollbackSpec::Later.run(items)

      expect(QueueProbe.drain_tracking("MapElementRollbackWorker")[:max_burst]).to be <= 5
    end

    it "loads at most one element context per rollback job" do
      current = nil
      loads = Hash.new(0)
      allow(storage).to receive(:retrieve_map_element_context_ids).and_call_original
      allow(storage).to receive(:retrieve_context).and_wrap_original do |original, id, name|
        loads[current] += 1 if current && name == MapRollbackFixtures::ElemOk.name
        original.call(id, name)
      end
      DistributedMapRollbackSpec::Later.run(items)

      drain_each { |job| current = rollback_job?(job) ? job : nil }

      expect(loads.size).to eq(20)
      expect(loads.values).to all(eq(1))
      expect(storage).not_to have_received(:retrieve_map_element_context_ids)
    end

    it "logs the rollback's start, each element and its completion" do
      io = StringIO.new
      allow(RubyReactor.configuration).to receive(:logger).and_return(Logger.new(io))

      fan_out_result(DistributedMapRollbackSpec::Later)

      lines = io.string.lines.grep(/event=.?ruby_reactor\.map\.rollback/)
      started = lines.grep(/rollback\.started/)
      elements = lines.grep(/rollback\.element/)
      completed = lines.grep(/rollback\.completed/)
      expect([started.size, elements.size, completed.size]).to eq([1, 20, 1])
      expect(lines).to all(match(/reactor=.*context_id=.*map_step=/))
      expect(started.first).to match(/total=20.*batch_size=5/)
      expect(elements).to all(match(/index=\d+.*outcome=.*failures=\d+/))
      expect(completed.first).to match(/total=20.*failed=0/)
    end

    it "reports an expired element once, as the inline map does" do
      inline = DistributedMapRollbackSpec::ExpiresInline.run(items)
      fan_out = fan_out_result(DistributedMapRollbackSpec::Expires).result

      [inline, fan_out].each do |result|
        unavailable = result.rollback_failures.select { |entry| entry[:reason] == :context_unavailable }
        expect(unavailable.map { |entry| entry[:element_index] }).to eq([3])
      end
    end

    describe "manual undo" do
      let(:reactor) { DistributedMapRollbackSpec::Completes }

      def completed_run
        id = reactor.run(items).execution_id
        drain
        RollbackRecorder.reset!
        id
      end

      it "hands off as rolling_back and finishes cancelled, everything undone once" do
        id = completed_run

        reactor.undo(id)

        expect(reactor.find(id).context.status.to_s).to eq("rolling_back")
        expect(log).to include("undo:b")
        expect(log).not_to include("undo:a")

        drain

        expect(reactor.find(id).context.status.to_s).to eq("cancelled")
        DistributedMapRollbackSpec::ITEMS.each { |i| expect(log.count("undo:e.e1[#{i}]")).to eq(1) }
        expect(log.count("undo:a")).to eq(1)
      end

      it "rejects a second undo, and a cancel, while rolling back" do
        id = completed_run
        reactor.undo(id)

        expect { reactor.undo(id) }.to raise_error(RubyReactor::Error::ValidationError, /rollback already in progress/)
        expect { reactor.cancel(id: id, reason: "x") }
          .to raise_error(RubyReactor::Error::ValidationError, /rollback in progress; cannot cancel/)
        expect(reactor.find(id).context.status.to_s).to eq("rolling_back")

        drain

        expect(reactor.find(id).context.status.to_s).to eq("cancelled")
        expect(log).to include("undo:a")
      end

      it "raises while another owner holds the run's context lock" do
        id = completed_run
        stub_const("RubyReactor::Reactor::UNDO_LOCK_WAIT", 0)
        holder = RubyReactor::Lock.new("async:#{id}", owner: "live", ttl: 30, auto_extend: false)
        holder.acquire

        expect { reactor.undo(id) }.to raise_error(RubyReactor::Lock::AcquisitionError)
      ensure
        holder&.release
      end
    end
  end

  # The one `inline!` example (plan.md Complexity Tracking): element jobs run
  # inside dispatch, so the map rollback settles before `MapStep#undo` checks
  # and never hands off (R-05).
  it "never hands off in inline job-testing mode, and ends with the fake-mode Failure" do
    reactor = DistributedMapRollbackSpec::Later
    expected = fan_out_result(reactor).result
    statuses = []
    depth = 0
    max_depth = 0
    allow(storage).to receive(:store_context).and_wrap_original do |original, id, payload, name|
      statuses << JSON.parse(payload)["status"].to_s
      original.call(id, payload, name)
    end
    allow(storage).to receive(:mark_map_rollback_handed_off).and_call_original
    allow_any_instance_of(RubyReactor::Adapters::Sidekiq::Worker).to receive(:perform).and_wrap_original do |m, *a|
      depth += 1
      max_depth = [max_depth, depth].max
      m.call(*a)
    ensure
      depth -= 1
    end

    result = Sidekiq::Testing.inline! { reactor.run(items) }

    expect(statuses).not_to include("rolling_back")
    expect(storage).not_to have_received(:mark_map_rollback_handed_off)
    expect(max_depth).to eq(1)
    expect(shape(result)).to eq(shape(expected))
  end
end
