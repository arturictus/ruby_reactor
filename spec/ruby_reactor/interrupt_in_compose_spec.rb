# frozen_string_literal: true

require "spec_helper"

# 010: an `interrupt` inside a composed child pauses the root, which is resumed
# by naming the interrupt's step path from the root.
RSpec.describe "interrupt inside a composed child" do
  let(:fx) { InterruptInComposeFixtures }
  let(:log) { RollbackRecorder.log }

  before do
    RollbackRecorder.reset!
    InterruptInComposeFixtures.on_c2 = nil
  end

  def stored(reactor, id)
    reactor.find(id).context
  end

  def compose_undos(reactor, id)
    stored(reactor, id).execution_trace.count { |e| e[:type].to_s == "undo" && e[:step].to_s == "fulfil" }
  end

  describe "pausing" do
    it "pauses the root, naming it in the result" do
      result = fx::Root.run({})

      expect(result).to be_a(RubyReactor::InterruptResult)
      expect(result.paused?).to be(true)
      context = stored(fx::Root, result.execution_id)
      expect(context.context_id).to eq(result.execution_id)
      expect(context.reactor_class).to eq(fx::Root)
      expect(context.status.to_s).to eq("paused")
      expect(context.current_step).to eq(:fulfil)
      expect(log).to eq(%w[run:r1 run:child.c1])
    end

    it "carries the child interrupt's correlation id, which resolves to the root" do
      result = fx::Root.run({})

      expect(result.correlation_id).to eq("approve-r1-value")
      expect(fx::Root.find_by_correlation_id("approve-r1-value").context.context_id).to eq(result.execution_id)
    end

    it "pauses the top-level root two composes deep" do
      result = fx::Top.run({})

      expect(stored(fx::Top, result.execution_id).status.to_s).to eq("paused")
      expect(log).to eq(%w[run:r1 run:middle.r1 run:child.c1])
    end
  end

  describe "resuming" do
    let(:path) { %i[fulfil approve] }
    let(:payload) { { ok: true } }

    def child_context(reactor, id, at: :fulfil)
      stored(reactor, id).composed_contexts[at][:context]
    end

    it "resumes the child at its interrupt and finishes the root, each step once" do
      id = fx::Root.run({}).execution_id

      result = fx::Root.continue(id: id, payload: payload, step_name: path)

      expect(result).to be_success
      expect(stored(fx::Root, id).status.to_s).to eq("completed")
      expect(log).to eq(%w[run:r1 run:child.c1 run:child.c2 run:r2])
      expect(child_context(fx::Root, id).intermediate_results[:c2]).to eq(payload)
    end

    it "takes the path as strings, as a JSON body sends it" do
      id = fx::Root.run({}).execution_id

      fx::Root.continue(id: id, payload: payload, step_name: %w[fulfil approve])

      expect(stored(fx::Root, id).status.to_s).to eq("completed")
    end

    it "resumes by the child interrupt's correlation id on the root class" do
      id = fx::Root.run({}).execution_id

      fx::Root.continue_by_correlation_id(correlation_id: "approve-r1-value", payload: payload, step_name: path)

      expect(stored(fx::Root, id).status.to_s).to eq("completed")
    end

    [:approve, %i[fulfil nope], %i[r2 approve], :r2, :fulfil].each do |wrong|
      it "refuses #{wrong.inspect}, naming the pending path, and changes nothing" do
        id = fx::Root.run({}).execution_id

        expect { fx::Root.continue(id: id, payload: payload, step_name: wrong) }
          .to raise_error(RubyReactor::Error::ValidationError, /\[:fulfil, :approve\]/)
        expect(stored(fx::Root, id).status.to_s).to eq("paused")
        expect(log).to eq(%w[run:r1 run:child.c1])
      end
    end

    it "refuses to resume the child on its own, by id or by correlation id" do
      id = fx::Root.run({}).execution_id
      child_id = child_context(fx::Root, id).context_id

      expect { fx::Child.continue(id: child_id, payload: payload, step_name: :approve) }
        .to raise_error(RubyReactor::Error::ValidationError, /composed child/)
      expect do
        fx::Child.continue_by_correlation_id(correlation_id: "approve-r1-value", payload: payload, step_name: :approve)
      end.to raise_error(RubyReactor::Error::ValidationError, /composed child/)
      expect(log).to eq(%w[run:r1 run:child.c1])
    end

    it "counts invalid payloads per nested interrupt and keeps the run paused" do
      id = fx::ValidatedRetryRoot.run({}).execution_id

      2.times do
        expect { fx::ValidatedRetryRoot.continue(id: id, payload: { ok: "x" }, step_name: path) }
          .to raise_error(RubyReactor::Error::InputValidationError)
      end
      context = stored(fx::ValidatedRetryRoot, id)
      expect(context.status.to_s).to eq("paused")
      expect(context.private_data[:interrupt_attempts][:"fulfil.approve"]).to eq(2)

      fx::ValidatedRetryRoot.continue(id: id, payload: payload, step_name: path)
      expect(stored(fx::ValidatedRetryRoot, id).status.to_s).to eq("completed")
    end

    it "pauses again at the child's next interrupt" do
      id = fx::TwoInterruptsRoot.run({}).execution_id

      fx::TwoInterruptsRoot.continue(id: id, payload: payload, step_name: path)
      expect(fx::TwoInterruptsRoot.find(id).ready_interrupt_steps).to eq([%i[fulfil sign]])

      fx::TwoInterruptsRoot.continue(id: id, payload: {}, step_name: %i[fulfil sign])
      expect(stored(fx::TwoInterruptsRoot, id).status.to_s).to eq("completed")
      expect(log).to eq(%w[run:r1 run:child.c1 run:child.c2 run:r2])
    end

    it "lists a root interrupt beside the nested one and takes both resumes" do
      id = fx::RootWithOwnInterrupt.run({}).execution_id
      expect(fx::RootWithOwnInterrupt.find(id).ready_interrupt_steps).to contain_exactly(:audit, path)

      fx::RootWithOwnInterrupt.continue(id: id, payload: {}, step_name: :audit)
      expect(fx::RootWithOwnInterrupt.find(id).ready_interrupt_steps).to eq([path])

      fx::RootWithOwnInterrupt.continue(id: id, payload: payload, step_name: path)
      expect(stored(fx::RootWithOwnInterrupt, id).status.to_s).to eq("completed")
      expect(log.count("run:child.c1")).to eq(1)
    end

    it "names an interrupt two composes deep by its full path" do
      id = fx::Top.run({}).execution_id
      deep = %i[order fulfil approve]
      expect(fx::Top.find(id).ready_interrupt_steps).to eq([deep])

      fx::Top.continue(id: id, payload: payload, step_name: deep)

      expect(stored(fx::Top, id).status.to_s).to eq("completed")
      expect(log.count("run:r2")).to eq(1)
      expect(log.count("run:middle.r2")).to eq(1)
    end

    it "leaves the run paused when the resume is contended on the root's lock, so it can be retried" do
      id = fx::LockedRoot.run({}).execution_id
      holder = RubyReactor::Lock.new("interrupt-in-compose:locked", owner: "another-run", auto_extend: false)
      holder.acquire

      expect { fx::LockedRoot.continue(id: id, payload: payload, step_name: path) }
        .to raise_error(RubyReactor::Lock::AcquisitionError)
      expect(stored(fx::LockedRoot, id).status.to_s).to eq("paused")

      holder.release
      fx::LockedRoot.continue(id: id, payload: payload, step_name: path)
      expect(stored(fx::LockedRoot, id).status.to_s).to eq("completed")
      expect(log).to eq(%w[run:r1 run:child.c1 run:child.c2 run:r2])
    end

    it "refuses a second resume while the first is executing" do
      id = fx::Root.run({}).execution_id
      errors = []
      InterruptInComposeFixtures.on_c2 = lambda do |_ctx|
        fx::Root.continue(id: id, payload: payload, step_name: path)
      rescue RubyReactor::Error::ValidationError => e
        errors << e
      end

      fx::Root.continue(id: id, payload: payload, step_name: path)

      expect(errors.map(&:message)).to contain_exactly(/running, not paused/)
      expect(stored(fx::Root, id).status.to_s).to eq("completed")
    end

    describe "undo and cancel" do
      it "undoes the child's completed steps before the root's and cancels the run" do
        id = fx::Root.run({}).execution_id

        fx::Root.undo(id)

        expect(log).to eq(%w[run:r1 run:child.c1 undo:child.c1 undo:r1])
        expect(stored(fx::Root, id).status.to_s).to eq("cancelled")
      end

      it "reaches the child two composes deep" do
        id = fx::Top.run({}).execution_id

        fx::Top.undo(id)

        expect(log.last(3)).to eq(%w[undo:child.c1 undo:middle.r1 undo:r1])
      end

      it "undoes the compose once after a resume completed it" do
        id = fx::Root.run({}).execution_id
        fx::Root.continue(id: id, payload: payload, step_name: path)

        fx::Root.undo(id)

        expect(log.grep(/\Aundo:/)).to eq(%w[undo:r2 undo:child.c2 undo:child.c1 undo:r1])
        expect(compose_undos(fx::Root, id)).to eq(1)
      end

      it "undoes once after the child paused twice in place" do
        id = fx::RootWithOwnInterrupt.run({}).execution_id
        fx::RootWithOwnInterrupt.continue(id: id, payload: {}, step_name: :audit)

        fx::RootWithOwnInterrupt.undo(id)

        expect(log.grep(/\Aundo:/)).to eq(%w[undo:child.c1 undo:r1])
        expect(compose_undos(fx::RootWithOwnInterrupt, id)).to eq(1)
      end

      it "refuses every resume once cancelled" do
        id = fx::Root.run({}).execution_id
        fx::Root.cancel(id: id, reason: "no")

        expect { fx::Root.continue(id: id, payload: payload, step_name: path) }
          .to raise_error(RubyReactor::Error::ValidationError, /cancelled/)
        expect(log).to eq(%w[run:r1 run:child.c1])
      end

      it "rolls the whole run back from the root when the nested interrupt's attempts run out" do
        id = fx::ValidatedRoot.run({}).execution_id

        result = fx::ValidatedRoot.continue(id: id, payload: { ok: "x" }, step_name: path)

        expect(result).to be_failure
        expect(log.grep(/\Aundo:/)).to eq(%w[undo:child.c1 undo:r1])
        expect(stored(fx::ValidatedRoot, id).status.to_s).to eq("failed")
      end
    end

    describe "with `resume: :background`" do
      for_each_async_backend do
        it "validates in the caller and runs the rest in the root's worker, never the child's" do
          router = RubyReactor.configuration.async_router
          allow(router).to receive(:perform_async).and_call_original
          id = fx::BackgroundRoot.run({}).execution_id
          child_id = child_context(fx::BackgroundRoot, id).context_id

          result = fx::BackgroundRoot.continue(id: id, payload: payload, step_name: path)
          expect(result).to be_a(RubyReactor::DispatchResult)
          RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs(max_iterations: 50)

          expect(stored(fx::BackgroundRoot, id).status.to_s).to eq("completed")
          expect(router).to have_received(:perform_async).with(id, fx::BackgroundRoot.name, anything)
          expect(router).not_to have_received(:perform_async).with(child_id, anything, anything)
        end
      end
    end
  end

  describe "an interrupt inside a map element" do
    def expect_unsupported(reactor)
      result = reactor.run(items: [1, 2])

      expect(result).to be_failure
      expect(result.error.to_s).to match(/not supported inside a map element/)
    end

    it "fails an inline map whose element pauses directly, undoing what the element completed" do
      expect_unsupported(fx::InlineDirectMap)
      expect(log.count("undo:e1[1]")).to eq(1)
    end

    it "fails an inline map whose element pauses through a compose" do
      expect_unsupported(fx::InlineComposedMap)
      expect(log.count("undo:child.c1")).to eq(1)
    end

    for_each_async_backend do
      it "fails a fan-out map whose element pauses through a compose" do
        id = fx::FanOutComposedMap.run(items: [1, 2]).execution_id
        RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs(max_iterations: 50)

        found = fx::FanOutComposedMap.find(id)
        expect(found.context.status.to_s).to eq("failed")
        expect(found.result.error.to_s).to match(/not supported inside a map element/)
      end
    end
  end
end
