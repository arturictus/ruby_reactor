# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Step outcome helpers (success!/skip!/fail!/halt!)" do
  UNREACHABLE = ->(*) { raise "unreachable line was executed" }

  describe "success!" do
    it "ends a class step immediately with Success, ignoring code after the call" do
      step_class = Class.new do
        include RubyReactor::Step

        def self.run(_args, _ctx)
          success!(:v)
          UNREACHABLE.call
        end
      end

      result = catch(RubyReactor::StepSignals::TAG) { step_class.run({}, nil) }
      expect(result).to be_a(RubyReactor::Success)
      expect(result.value).to eq(:v)
    end

    it "ends an inline-block step immediately with Success, ignoring code after the call" do
      reactor_class = Class.new(RubyReactor::Reactor) do
        step :only do
          run do |_args, _ctx|
            success!(:v)
            UNREACHABLE.call
          end
        end
        returns :only
      end

      result = reactor_class.run
      expect(result).to be_success
      expect(result.value).to eq(:v)
    end
  end

  describe "skip!" do
    it "ends a class step immediately with Skipped, ignoring code after the call" do
      step_class = Class.new do
        include RubyReactor::Step

        def self.run(_args, _ctx)
          skip!(:v)
          UNREACHABLE.call
        end
      end

      result = catch(RubyReactor::StepSignals::TAG) { step_class.run({}, nil) }
      expect(result).to be_a(RubyReactor::Skipped)
      expect(result.value).to eq(:v)
    end

    it "ends an inline-block step immediately with Skipped, and the reactor continues" do
      reactor_class = Class.new(RubyReactor::Reactor) do
        step :maybe do
          run do |_args, _ctx|
            skip!(:v)
            UNREACHABLE.call
          end
        end

        step :after do
          argument :value, result(:maybe)
          run { |args, _ctx| Success(args[:value]) }
        end

        returns :after
      end

      reactor = reactor_class.new
      result = reactor.run
      expect(result).to be_success
      expect(result.value).to eq(:v)
      expect(reactor.execution_trace.any? { |e| e[:type] == :skipped && e[:step] == :maybe }).to be true
    end
  end

  describe "fail!" do
    it "ends a class step immediately with Failure, ignoring code after the call" do
      step_class = Class.new do
        include RubyReactor::Step

        def self.run(_args, _ctx)
          fail!(StandardError.new("boom"))
          UNREACHABLE.call
        end
      end

      result = catch(RubyReactor::StepSignals::TAG) { step_class.run({}, nil) }
      expect(result).to be_a(RubyReactor::Failure)
    end

    it "ends an inline-block step immediately with Failure, ignoring code after the call" do
      reactor_class = Class.new(RubyReactor::Reactor) do
        step :only do
          run do |_args, _ctx|
            fail!(StandardError.new("boom"))
            UNREACHABLE.call
          end
        end
        returns :only
      end

      result = reactor_class.run
      expect(result).to be_failure
    end
  end

  describe "halt!" do
    it "ends a class step immediately with Halt, ignoring code after the call" do
      step_class = Class.new do
        include RubyReactor::Step

        def self.run(_args, _ctx)
          halt!(reason: "done")
          UNREACHABLE.call
        end
      end

      result = catch(RubyReactor::StepSignals::TAG) { step_class.run({}, nil) }
      expect(result).to be_a(RubyReactor::Halt)
      expect(result.reason).to eq("done")
    end

    it "ends an inline-block step immediately with Halt, ignoring code after the call" do
      reactor_class = Class.new(RubyReactor::Reactor) do
        step :only do
          run do |_args, _ctx|
            halt!(reason: "done")
            UNREACHABLE.call
          end
        end
        returns :only
      end

      result = reactor_class.run
      expect(result).to be_a(RubyReactor::Halt)
      expect(result.reason).to eq("done")
    end
  end

  describe "any call depth" do
    it "ends the step when called from a nested method" do
      step_class = Class.new do
        include RubyReactor::Step

        def self.run(args, _context)
          check!(args)
          UNREACHABLE.call
        end

        def self.check!(args)
          fail!("nope") unless args[:ok]
        end
      end

      result = catch(RubyReactor::StepSignals::TAG) { step_class.run({ ok: false }, nil) }
      expect(result).to be_a(RubyReactor::Failure)
    end
  end

  describe "broad rescues cannot swallow it" do
    it "escapes a rescue Exception inside the step body, and still runs ensure" do
      ensure_ran = []

      reactor_class = Class.new(RubyReactor::Reactor) do
        step :only do
          run do |_args, _ctx|
            halt!(reason: "escape")
            UNREACHABLE.call
          rescue Exception # rubocop:disable Lint/RescueException
            UNREACHABLE.call
          ensure
            ensure_ran << true
          end
        end
        returns :only
      end

      result = reactor_class.run
      expect(result).to be_a(RubyReactor::Halt)
      expect(ensure_ran).to eq([true])
    end
  end

  describe "compensate and undo bodies" do
    it "is usable inside a class step's compensate" do
      step_class = Class.new do
        include RubyReactor::Step

        def self.run(_args, _ctx)
          Failure("boom")
        end

        def self.compensate(_reason, _args, _ctx)
          success!(:compensated)
        end
      end

      result = catch(RubyReactor::StepSignals::TAG) { step_class.compensate("reason", {}, nil) }
      expect(result).to be_a(RubyReactor::Success)
      expect(result.value).to eq(:compensated)
    end

    it "is usable inside a class step's undo" do
      step_class = Class.new do
        include RubyReactor::Step

        def self.run(_args, _ctx)
          Success(:done)
        end

        def self.undo(_result, _args, _ctx)
          success!(:undone)
        end
      end

      result = catch(RubyReactor::StepSignals::TAG) { step_class.undo(nil, {}, nil) }
      expect(result).to be_a(RubyReactor::Success)
      expect(result.value).to eq(:undone)
    end
  end

  describe "the Skipped migration guard applies to skip! too" do
    it "raises ArgumentError when called with only reason:" do
      step_class = Class.new do
        include RubyReactor::Step

        def self.run(_args, _ctx)
          skip!(reason: "x")
        end
      end

      expect { step_class.run({}, nil) }.to raise_error(ArgumentError, /Halt/)
    end

    it "passes an explicit hash through as the skipped value" do
      step_class = Class.new do
        include RubyReactor::Step

        def self.run(_args, _ctx)
          skip!({ reason: "x" })
        end
      end

      result = catch(RubyReactor::StepSignals::TAG) { step_class.run({}, nil) }
      expect(result).to be_a(RubyReactor::Skipped)
      expect(result.value).to eq({ reason: "x" })
    end
  end
end
