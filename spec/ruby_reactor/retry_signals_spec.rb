# frozen_string_literal: true

require "spec_helper"

class RetryFalseAsyncReactor < RubyReactor::Reactor
  background all: true
  step :flaky do
    retries max_attempts: 3, base_delay: 0
    run { |_args, _ctx| fail!(StandardError.new("boom"), retry: false) }
  end
end

RSpec.describe "Retry interaction with success!/skip!/fail!/halt!" do
  it "fail!(e) on a 3-attempt step retries 3 times then rolls back" do
    attempts = []

    reactor_class = Class.new(RubyReactor::Reactor) do
      step :flaky do
        retries max_attempts: 3, base_delay: 0
        run do |_args, _ctx|
          attempts << 1
          fail!(StandardError.new("boom"))
        end
      end
    end

    result = reactor_class.run
    expect(result).to be_failure
    expect(attempts.size).to eq(3)
  end

  it "fail!(e, retry: false) makes exactly 1 attempt, no backoff sleep, straight to rollback" do
    attempts = []

    reactor_class = Class.new(RubyReactor::Reactor) do
      step :flaky do
        retries max_attempts: 3, base_delay: 10
        run do |_args, _ctx|
          attempts << 1
          fail!(StandardError.new("boom"), retry: false)
        end
      end
    end

    started_at = Time.now
    result = reactor_class.run
    elapsed = Time.now - started_at

    expect(result).to be_failure
    expect(attempts.size).to eq(1)
    expect(elapsed).to be < 5
  end

  it "skip! after 2 failed attempts completes the run, no exhaustion failure" do
    attempts = []

    reactor_class = Class.new(RubyReactor::Reactor) do
      step :flaky do
        retries max_attempts: 5, base_delay: 0
        run do |_args, _ctx|
          attempts << 1
          attempts.size < 3 ? fail!(StandardError.new("boom")) : skip!(:done_via_skip)
        end
      end

      returns :flaky
    end

    result = reactor_class.run
    expect(result).to be_success
    expect(result.value).to eq(:done_via_skip)
    expect(attempts.size).to eq(3)
  end

  it "halt! after 2 failed attempts halts the run, no rollback" do
    attempts = []
    undone = []

    reactor_class = Class.new(RubyReactor::Reactor) do
      step :first do
        run { |_args, _ctx| Success(:first_done) }
        undo do |_r, _a, _c|
          undone << :first
          Success()
        end
      end

      step :flaky do
        wait_for :first
        retries max_attempts: 5, base_delay: 0
        run do |_args, _ctx|
          attempts << 1
          attempts.size < 3 ? fail!(StandardError.new("boom")) : halt!(reason: "give up")
        end
      end
    end

    result = reactor_class.run
    expect(result).to be_a(RubyReactor::Halt)
    expect(attempts.size).to eq(3)
    expect(undone).to be_empty
  end

  it "a retry: false failure inside a background-executed step re-enqueues no job" do
    allow(RubyReactor::Adapters::Sidekiq::Worker).to receive(:perform_in)
    RetryFalseAsyncReactor.run
    RubyReactor::Adapters::Sidekiq::Worker.drain

    expect(RubyReactor::Adapters::Sidekiq::Worker).not_to have_received(:perform_in)
    expect(RubyReactor::Adapters::Sidekiq::Worker.jobs).to be_empty
  end

  it "fail!(e, retry: true) on a step with no retry config still makes only 1 attempt" do
    attempts = []

    reactor_class = Class.new(RubyReactor::Reactor) do
      step :no_retry_config do
        run do |_args, _ctx|
          attempts << 1
          fail!(StandardError.new("boom"), retry: true)
        end
      end
    end

    result = reactor_class.run
    expect(result).to be_failure
    expect(attempts.size).to eq(1)
  end
end
