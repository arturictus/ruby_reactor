# frozen_string_literal: true

require "spec_helper"

# 009 US2: a fan-out map inside a composed child, at any depth. The map's
# completion resumes the top-level run (R-03), and rollback travels through it
# (S-3), distributed per US1.
module MapComposeFanOutSpec
  F = MapRollbackFixtures

  def self.child(name, element: F::ElemOk, distributed: true, c2_fails: false, c2_undo_fails: false)
    klass = Class.new(RollbackRecorder::Reactor) do
      tag "child"
      input :items
      input :fail_at, optional: true
      input :seed, optional: true
      recording_step :c1
      map :m, element do
        source input(:items)
        argument :i, element(:m)
        argument :fail_at, input(:fail_at)
        fan_out(batch_size: 1) if distributed
      end
      recording_step :c2, after: :m, fail: c2_fails, undo_fails: c2_undo_fails
    end
    const_set(name, klass)
  end

  def self.root(name, composed, r2_fails: false)
    klass = Class.new(RollbackRecorder::Reactor) do
      input :items
      input :fail_at, optional: true
      input :seed, optional: true
      recording_step :r1
      compose(:c, composed) do
        argument :items, input(:items)
        argument :fail_at, input(:fail_at)
        argument :seed, result(:r1)
      end
      recording_step :r2, after: :c, fail: r2_fails
    end
    const_set(name, klass)
  end

  child :Child
  root :Root, Child
  root :Middle, Child
  root :Top, Middle
  root :LaterFailure, Child, r2_fails: true
  child :InlineChild, distributed: false
  root :LaterFailureInline, InlineChild, r2_fails: true
  child :AtomicChild, element: F::Elem
  root :ElementFails, AtomicChild
  child :ChildStepFails, c2_fails: true
  root :ChildStepFailsRoot, ChildStepFails
  child :ChildUndoFails, c2_undo_fails: true
  root :ChildUndoFailsRoot, ChildUndoFails, r2_fails: true
end

RSpec.describe "fan-out map inside a composed child" do
  let(:storage) { RubyReactor.configuration.storage_adapter }
  let(:log) { RollbackRecorder.log }
  let(:items) { { items: [0, 1, 2, 3] } }

  before { RollbackRecorder.reset! }

  def drain
    RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs(max_iterations: 500)
  end

  def run(reactor, inputs = items)
    id = reactor.run(inputs).execution_id
    drain
    reactor.find(id)
  end

  def element_undos
    log.grep(/\Aundo:e\./)
  end

  for_each_async_backend do
    it "resumes the root after the map and finishes it" do
      found = run(MapComposeFanOutSpec::Root)

      expect(found.context.status.to_s).to eq("completed")
      expect(found.context.intermediate_results[:r2]).to eq("r2-value")
    end

    it "resumes the root once the child's interrupt after the map is continued" do
      pending "an interrupt inside a composed child is unsupported on main, fan-out or not (Step 'c' fails with " \
              "NoMethodError on InterruptResult); out of 009's scope"
      found = run(MapComposeFanOutSpec::Root)

      expect(found.context.status.to_s).to eq("paused")
    end

    it "resumes the top-level root with the map two composes deep" do
      found = run(MapComposeFanOutSpec::Top)

      expect(found.context.status.to_s).to eq("completed")
    end

    it "signals the root's Worker, never the child's" do
      router = RubyReactor.configuration.async_router
      allow(router).to receive(:perform_async).and_call_original
      id = MapComposeFanOutSpec::Root.run(items).execution_id
      drain

      child_id = MapComposeFanOutSpec::Root.find(id).context.composed_contexts[:c][:context].context_id
      expect(router).to have_received(:perform_async).with(id, MapComposeFanOutSpec::Root.name).at_least(:once)
      expect(router).not_to have_received(:perform_async).with(child_id, anything)
    end

    describe "rollback through the root" do
      it "undoes every element, then the child's earlier steps, then the root's, when a root step fails" do
        found = run(MapComposeFanOutSpec::LaterFailure)

        expect(found.context.status.to_s).to eq("failed")
        expect(element_undos.size).to eq(8)
        expect(log.rindex { |event| event.start_with?("undo:e.") }).to be < log.index("undo:child.c1")
        expect(log.index("undo:child.c1")).to be < log.index("undo:r1")
      end

      it "fails the root when an element fails under atomic" do
        found = run(MapComposeFanOutSpec::ElementFails, items.merge(fail_at: 2))

        expect(found.context.status.to_s).to eq("failed")
        completed = log.grep(/\Arun:e\.e2\[(\d)\]/) { Regexp.last_match(1).to_i } - [2]
        completed.each { |i| expect(log.count("undo:e.e2[#{i}]")).to eq(1) }
        expect(log.last(2)).to eq(%w[undo:child.c1 undo:r1])
      end

      it "fails the root when the child's step after the map fails" do
        found = run(MapComposeFanOutSpec::ChildStepFailsRoot)

        expect(found.context.status.to_s).to eq("failed")
        expect(element_undos.size).to eq(8)
        expect(log.last(2)).to eq(%w[undo:child.c1 undo:r1])
      end

      it "ends with the same Failure as the same tree with an inline map" do
        inline = MapComposeFanOutSpec::LaterFailureInline.run(items)
        inline_undone = element_undos.to_set
        RollbackRecorder.reset!

        fan_out = run(MapComposeFanOutSpec::LaterFailure).result

        expect([fan_out.error.to_s, fan_out.step_name.to_s, fan_out.rollback_failures])
          .to eq([inline.error.to_s, inline.step_name.to_s, inline.rollback_failures])
        expect(element_undos.to_set).to eq(inline_undone)
      end

      it "undoes everything once on a manual undo from the root" do
        id = MapComposeFanOutSpec::Root.run(items).execution_id
        drain
        RollbackRecorder.reset!

        MapComposeFanOutSpec::Root.undo(id)
        expect(MapComposeFanOutSpec::Root.find(id).context.status.to_s).to eq("rolling_back")
        drain

        expect(MapComposeFanOutSpec::Root.find(id).context.status.to_s).to eq("cancelled")
        expect(element_undos.tally.values).to all(eq(1))
        expect(element_undos.size).to eq(8)
        %w[undo:child.c2 undo:child.c1 undo:r1].each { |event| expect(log.count(event)).to eq(1) }
      end

      it "keeps a child step's undo failure recorded before the hand-off" do
        found = run(MapComposeFanOutSpec::ChildUndoFailsRoot)

        expect(log.index("undo:child.c2")).to be < log.index { |event| event.start_with?("undo:e.") }
        expect(found.result.rollback_failures).to include(a_hash_including(step: :c2, kind: :undo))
      end
    end
  end
end
