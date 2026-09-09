# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Skipped step result" do
  it "lets a dependant read the skipped step's value" do
    reactor_class = Class.new(RubyReactor::Reactor) do
      step :maybe_sync do
        run { |_args, _ctx| Skipped(:cached_user) }
      end

      step :notify do
        argument :user, result(:maybe_sync)
        run { |args, _ctx| Success("notified:#{args[:user]}") }
      end

      returns :notify
    end

    result = reactor_class.run
    expect(result).to be_success
    expect(result.value).to eq("notified:cached_user")
  end

  it "yields an empty value without erroring when skipped with no value" do
    reactor_class = Class.new(RubyReactor::Reactor) do
      step :maybe_sync do
        run { |_args, _ctx| Skipped() }
      end

      step :notify do
        argument :user, result(:maybe_sync)
        run { |args, _ctx| Success(args[:user].inspect) }
      end

      returns :notify
    end

    result = reactor_class.run
    expect(result).to be_success
    expect(result.value).to eq("nil")
  end

  it "returns the skipped value when the return_step is skipped" do
    reactor_class = Class.new(RubyReactor::Reactor) do
      step :only do
        run { |_args, _ctx| Skipped(:the_value) }
      end

      returns :only
    end

    result = reactor_class.run
    expect(result).to be_success
    expect(result.value).to eq(:the_value)
  end

  it "completes when every step is skipped" do
    reactor_class = Class.new(RubyReactor::Reactor) do
      step :first do
        run { |_args, _ctx| Skipped(:a) }
      end

      step :second do
        wait_for :first
        run { |_args, _ctx| Skipped(:b) }
      end

      returns :second
    end

    result = reactor_class.run
    expect(result).to be_success
    expect(result.halted?).to be false
  end

  it "leaves the run status completed, not halted" do
    reactor_class = Class.new(RubyReactor::Reactor) do
      step :maybe_sync do
        run { |_args, _ctx| Skipped(:v) }
      end

      returns :maybe_sync
    end

    reactor = reactor_class.new
    reactor.run
    expect(reactor.context.status.to_s).to eq("completed")
  end

  it "subjects a skipped step's value to the step's declared output validation" do
    reactor_class = Class.new(RubyReactor::Reactor) do
      step :maybe_sync do
        run { |_args, _ctx| Skipped(-1) }
        validate_output :integer, gteq?: 0
      end

      returns :maybe_sync
    end

    result = reactor_class.run
    expect(result).to be_failure
  end

  it "passes a skipped step's value through output validation when valid" do
    reactor_class = Class.new(RubyReactor::Reactor) do
      step :maybe_sync do
        run { |_args, _ctx| Skipped(5) }
        validate_output :integer, gteq?: 0
      end

      returns :maybe_sync
    end

    result = reactor_class.run
    expect(result).to be_success
    expect(result.value).to eq(5)
  end
end
