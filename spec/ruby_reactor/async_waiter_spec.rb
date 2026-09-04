# frozen_string_literal: true

require "spec_helper"

# The shared wait core, exercised against real Redis pub/sub. Its
# contract is "the durable record is the answer, the signal is only latency":
# every path here must end at the durable check, so a lost/absent signal costs
# time and never correctness.
RSpec.describe RubyReactor::AsyncWaiter do
  let(:channel) { "rr:done:test:#{SecureRandom.uuid}" }
  let(:storage) { RubyReactor.configuration.storage_adapter }

  around do |example|
    original = RubyReactor.configuration.async_wait_timeout
    RubyReactor.configuration.async_wait_timeout = 3
    example.run
  ensure
    RubyReactor.configuration.async_wait_timeout = original
  end

  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  def waiter(channel: self.channel, timeout: nil, &terminal_check)
    described_class.new(channel: channel, timeout: timeout, &terminal_check)
  end

  it "returns immediately when the durable target is already terminal" do
    took = elapsed do
      expect(waiter { { "status" => "completed" } }.wait).to eq({ "status" => "completed" })
    end

    expect(took).to be < 1
  end

  it "wakes on a published signal rather than waiting out the fallback interval" do
    terminal = false
    publisher = Thread.new do
      sleep 0.2
      terminal = true
      storage.publish(channel, "done")
    end

    took = elapsed do
      expect(waiter { terminal ? :done : nil }.wait).to eq(:done)
    end

    publisher.join
    # The fallback re-check is 1s (timeout 3 / 10, clamped to >= 1), so
    # finishing well inside that proves the signal — not the poll — woke us.
    expect(took).to be < 0.9
  end

  it "still resolves when no signal is ever published (fallback re-check)" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    # Never publishes. Only the coarse re-check can find this.
    expect(waiter { (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) > 0.1 ? :late : nil }.wait)
      .to eq(:late)
  end

  it "raises AsyncWaitTimeoutError at the bound" do
    took = elapsed do
      expect { waiter(timeout: 1) { nil }.wait }
        .to raise_error(RubyReactor::Error::AsyncWaitTimeoutError, /1/)
    end

    expect(took).to be_within(0.6).of(1)
  end

  it "names what it was waiting for in the timeout message" do
    expect { waiter(timeout: 1) { nil }.wait }.to raise_error(/#{Regexp.escape(channel)}/)
  end

  it "defaults its bound to Configuration#async_wait_timeout" do
    expect(waiter { :x }.timeout).to eq(3)
  end

  it "does not leave the subscriber connection blocking the shared client" do
    waiter(timeout: 1) { :immediate }.wait

    # The shared client must still be usable — SUBSCRIBE would have poisoned it.
    expect { storage.publish(channel, "ping") }.not_to raise_error
  end
end
