# frozen_string_literal: true

require "spec_helper"

# Phase 2 (Foundational): steps can declare all five coordination macros and
# the declarations are inspectable. Nothing is enforced yet — that starts in
# US1 (lock_spec.rb). This spec only exercises the declaration surface itself.
RSpec.describe "step-scoped coordination declarations" do
  describe "a class step" do
    let(:step_class) do
      Class.new(RubyReactor::Step) do
        with_lock(ttl: 30, wait: 1) { |args| "lock:#{args[:id]}" }
        with_semaphore(limit: 2, wait: 1) { |args| "sem:#{args[:id]}" }
        with_rate_limit(limit: 5, period: :minute) { |args| "rl:#{args[:id]}" }
        with_period(every: :hour) { |args| "period:#{args[:id]}" }
        with_ordered_lock(strict: false) { |args| "ordered:#{args[:id]}" }

        def run
          Success(nil)
        end
      end
    end

    it "exposes the same per-macro readers a reactor gets" do
      expect(step_class.lock_config[:ttl]).to eq(30)
      expect(step_class.semaphore_config[:limit]).to eq(2)
      expect(step_class.rate_limit_config[:limits]).to be_an(Array)
      expect(step_class.period_config[:every]).to eq(:hour)
      expect(step_class.ordered_lock_config[:strict]).to be(false)
    end

    it "still raises ArgumentError for with_rate_limit(:name) combined with other options" do
      expect do
        Class.new(RubyReactor::Step) { with_rate_limit(:stripe, limit: 5) }
      end.to raise_error(ArgumentError)
    end

    it "still raises at class load for an unknown with_period every:" do
      expect do
        Class.new(RubyReactor::Step) { with_period(every: :bogus) }
      end.to raise_error(ArgumentError)
    end

    it "propagates configs to a subclass" do
      subclass = Class.new(step_class)
      expect(subclass.lock_config[:ttl]).to eq(30)
    end

    it "lets a subclass replace a parent's declaration" do
      subclass = Class.new(step_class) do
        with_lock(ttl: 99) { |args| "other:#{args[:id]}" }
      end
      expect(subclass.lock_config[:ttl]).to eq(99)
      # Unrelated primitives are still inherited.
      expect(subclass.semaphore_config[:limit]).to eq(2)
    end

    it "declares_coordination? is false for a bare step" do
      bare = Class.new(RubyReactor::Step) { def run = Success(nil) }
      expect(bare.declares_coordination?).to be(false)
    end

    it "declares_coordination? is true once any macro is used" do
      expect(step_class.declares_coordination?).to be(true)
    end

    it "coordination_declarations returns only the declared keys" do
      only_lock = Class.new(RubyReactor::Step) { with_lock { |a| "k:#{a[:id]}" } }
      expect(only_lock.coordination_declarations.keys).to eq([:lock])
      expect(step_class.coordination_declarations.keys).to contain_exactly(
        :lock, :semaphore, :rate_limit, :period, :ordered_lock
      )
    end
  end

  describe "an inline step" do
    let(:reactor_class) do
      Class.new(RubyReactor::Reactor) do
        input :id

        step :x do
          argument :id, input(:id)
          with_lock { |args| "inline:#{args[:id]}" }
          run { |args, _ctx| RubyReactor.Success(args) }
        end

        returns :x
      end
    end

    it "exposes lock_config on the step's StepConfig" do
      step_config = reactor_class.steps[:x]
      expect(step_config.lock_config[:key_proc].call(id: 7)).to eq("inline:7")
    end
  end

  describe "StepConfig fallback between inline declarations and impl" do
    let(:step_impl) do
      Class.new(RubyReactor::Step) do
        with_lock { |args| "impl:#{args[:id]}" }
        def run = Success(nil)
      end
    end

    it "falls back to impl.lock_config when the block declares nothing" do
      reactor_class = build_reactor_with_step(step_impl) # no lock declared inline
      step_config = reactor_class.steps[:x]
      expect(step_config.lock_config[:key_proc].call(id: 1)).to eq("impl:1")
    end

    it "prefers the step's own inline declaration when both declare" do
      impl = step_impl
      reactor_class = Class.new(RubyReactor::Reactor) do
        input :id
        step :x, impl do
          argument :id, input(:id)
          with_lock { |args| "wiring:#{args[:id]}" }
        end
        returns :x
      end
      step_config = reactor_class.steps[:x]
      expect(step_config.lock_config[:key_proc].call(id: 1)).to eq("wiring:1")
    end

    def build_reactor_with_step(impl)
      Class.new(RubyReactor::Reactor) do
        input :id
        step :x, impl do
          argument :id, input(:id)
        end
        returns :x
      end
    end
  end

  describe "interrupt steps" do
    it "raises at class definition when a coordination macro is declared inside interrupt" do
      expect do
        Class.new(RubyReactor::Reactor) do
          interrupt(:approval) { with_lock { |a| "k:#{a[:id]}" } }
        end
      end.to raise_error(RubyReactor::Error::ValidationError, /Declare it on the reactor/)
    end

    it "names reactor-level coordination as the alternative for each macro" do
      %i[with_lock with_semaphore with_rate_limit with_period with_ordered_lock].each do |macro|
        expect do
          Class.new(RubyReactor::Reactor) { interrupt(:approval) { send(macro, limit: 1) { "k" } } }
        end.to raise_error(RubyReactor::Error::ValidationError, /Declare it on the reactor \(with_lock etc\.\)/)
      end
    end
  end

  describe "reactor-level coordination is unchanged" do
    it "an existing reactor with with_lock still exposes lock_config the same way" do
      reactor_class = Class.new(RubyReactor::Reactor) do
        input :id
        with_lock(ttl: 10) { |inputs| "reactor:#{inputs[:id]}" }
        step :x do
          run { RubyReactor.Success(nil) }
        end
        returns :x
      end

      expect(reactor_class.lock_config[:ttl]).to eq(10)
      expect(reactor_class.lock_config[:key_proc].call(id: 5)).to eq("reactor:5")
    end
  end
end
