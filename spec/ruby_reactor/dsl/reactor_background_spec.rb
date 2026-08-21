# frozen_string_literal: true

require "spec_helper"

# US1: one unambiguous hand-off point per reactor, nameable from either side.
RSpec.describe "reactor-level `background` hand-off" do
  before do
    BackgroundFixtures.reset!
    BackgroundCompensationReactor.reset!
  end

  def define_reactor(&block)
    Class.new(RubyReactor::Reactor, &block)
  end

  describe "`after: :second`" do
    for_each_async_backend do
      it "runs everything up to and including the named step in the calling process" do
        result = BackgroundAfterReactor.run

        expect(result).to be_a(RubyReactor::AsyncResult)
        expect(BackgroundFixtures.trace[:after]).to eq([%i[first here], %i[second here]])
      end

      it "runs the remaining steps in the dispatched job" do
        result = BackgroundAfterReactor.run
        RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs

        expect(BackgroundFixtures.trace[:after]).to eq(
          [%i[first here], %i[second here], %i[third worker]]
        )
        expect(BackgroundAfterReactor.find(result.execution_id).context.status.to_s).to eq("completed")
      end

      it "compensates a worker-side failure exactly as a same-process failure" do
        result = BackgroundCompensationReactor.run
        RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs

        context = BackgroundCompensationReactor.find(result.execution_id).context
        expect(context.status.to_s).to eq("failed")
        expect(BackgroundCompensationReactor.compensated).to include(:reserve)
      end
    end
  end

  describe "`before: :third`" do
    for_each_async_backend do
      it "never executes the named step in the calling process" do
        BackgroundBeforeReactor.run

        expect(BackgroundFixtures.trace[:before]).to eq([%i[first here], %i[second here]])
      end

      it "runs the named step first in the worker" do
        BackgroundBeforeReactor.run
        RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs

        expect(BackgroundFixtures.trace[:before]).to eq(
          [%i[first here], %i[second here], %i[third worker]]
        )
      end

      it "is equivalent to the `after:` form in a linear chain" do
        BackgroundAfterReactor.run
        RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs
        BackgroundBeforeReactor.run
        RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs

        expect(BackgroundFixtures.trace[:before]).to eq(BackgroundFixtures.trace[:after])
      end
    end
  end

  describe "in a branching DAG, where the two forms differ" do
    for_each_async_backend do
      it "`after: :audit` keeps :audit here and moves its sibling to the worker" do
        BackgroundBranchingAfterReactor.run
        RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs

        trace = BackgroundFixtures.trace[:branch_after].to_h
        expect(trace[:audit]).to eq(:here)
        expect(trace[:ship]).to eq(:worker)
      end

      it "`before: :ship` moves :ship to the worker and keeps its sibling here" do
        BackgroundBranchingBeforeReactor.run
        RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs

        trace = BackgroundFixtures.trace[:branch_before].to_h
        expect(trace[:ship]).to eq(:worker)
        expect(trace[:audit]).to eq(:here)
      end
    end
  end

  describe "trigger edge behavior" do
    for_each_async_backend do
      it "is keyed to reaching the step, not to the declaration's lexical position" do
        BackgroundDeclaredFirstReactor.run
        RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs

        expect(BackgroundFixtures.trace[:declared_first]).to eq(
          [%i[only_first here], %i[then_this worker]]
        )
      end

      it "never fires when the named step is skipped by a guard" do
        result = BackgroundSkippedTriggerReactor.run(hand_off: false)

        expect(result).not_to be_a(RubyReactor::AsyncResult)
        expect(BackgroundFixtures.trace[:skipped_trigger].map(&:last).uniq).to eq([:here])
      end

      it "does not re-trigger inside the worker" do
        BackgroundAfterReactor.run
        RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs

        # A re-trigger would leave :third unrun and queue another job forever.
        expect(RubyReactor::RSpec::AsyncTestHelpers.pending_async_jobs).to be_empty
        expect(BackgroundFixtures.trace[:after].last).to eq(%i[third worker])
      end
    end
  end

  describe "definition-time guards" do
    it "rejects a second, different hand-off point" do
      expect do
        define_reactor do
          step(:a) { run { RubyReactor.Success(:a) } }
          step(:b) { run { RubyReactor.Success(:b) } }
          background after: :a
          background after: :b
        end
      end.to raise_error(RubyReactor::Error::ValidationError, /exactly one hand-off point/)
    end

    it "treats re-declaring the identical point as a no-op, so class reloading is safe" do
      reactor = define_reactor do
        step(:a) { run { RubyReactor.Success(:a) } }
        background after: :a
        background after: :a
      end

      expect(reactor.background_handoff).to eq({ mode: :after, step: :a })
    end

    it "rejects an unknown step named via `after:`" do
      expect do
        define_reactor do
          step(:a) { run { RubyReactor.Success(:a) } }
          background after: :nope
        end
      end.to raise_error(RubyReactor::Error::ValidationError, /unknown step :nope/)
    end

    it "rejects an unknown step named via `before:`" do
      expect do
        define_reactor do
          step(:a) { run { RubyReactor.Success(:a) } }
          background before: :nope
        end
      end.to raise_error(RubyReactor::Error::ValidationError, /unknown step :nope/)
    end

    it "rejects supplying both `after:` and `before:`" do
      expect do
        define_reactor do
          step(:a) { run { RubyReactor.Success(:a) } }
          step(:b) { run { RubyReactor.Success(:b) } }
          background after: :a, before: :b
        end
      end.to raise_error(RubyReactor::Error::ValidationError, /exactly one of/)
    end

    it "rejects supplying neither" do
      expect do
        define_reactor do
          step(:a) { run { RubyReactor.Success(:a) } }
          background
        end
      end.to raise_error(RubyReactor::Error::ValidationError, /requires either/)
    end

    it "rejects `background` on a reactor already declared `async true`" do
      expect do
        define_reactor do
          async true
          step(:a) { run { RubyReactor.Success(:a) } }
          background after: :a
        end
      end.to raise_error(RubyReactor::Error::ValidationError, /already runs entirely in a worker/)
    end

    it "rejects `async true` on a reactor that already declared `background`" do
      expect do
        define_reactor do
          step(:a) { run { RubyReactor.Success(:a) } }
          background after: :a
          async true
        end
      end.to raise_error(RubyReactor::Error::ValidationError, /cannot be combined/)
    end
  end

  it "exposes the point as one normalized pair, never a one-sided reader" do
    reactor = define_reactor do
      step(:a) { run { RubyReactor.Success(:a) } }
      background before: :a
    end

    expect(reactor.background_handoff).to eq({ mode: :before, step: :a })
    expect(reactor).not_to respond_to(:background_after)
  end

  it "is nil for a reactor that never declares one" do
    reactor = define_reactor do
      step(:a) { run { RubyReactor.Success(:a) } }
    end

    expect(reactor.background_handoff).to be_nil
  end
end
