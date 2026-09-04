# frozen_string_literal: true

require "spec_helper"

# The notified wait is bounded, and it is the DURABLE RECORD that
# answers — the completion signal is only a latency optimisation. Each example
# here removes one of the three things that could go wrong (signal too early,
# signal never sent, work never finishes) and shows the wait still behaves.
RSpec.describe "`async_step` notified wait" do
  let(:storage) { RubyReactor.configuration.storage_adapter }

  around do |example|
    original = RubyReactor.configuration.async_wait_timeout
    RubyReactor.configuration.async_wait_timeout = 2
    example.run
  ensure
    RubyReactor.configuration.async_wait_timeout = original
  end

  # A context carrying a dispatched async_step reference, with no live worker —
  # so the spec controls exactly when (and whether) the record and the signal
  # appear. No caller is blocked on a fake queue here, which is why this stays
  # in the unit lane.
  def context_with_ref(step_name = :unit)
    reactor_class = Class.new(RubyReactor::Reactor) do
      def self.name = "AsyncStepWaitSpecReactor"
    end
    context = RubyReactor::Context.new({}, reactor_class)
    context.composed_contexts[step_name] = {
      name: step_name, type: :async_step_ref, context_id: context.context_id, dispatched_at: Time.now
    }
    context
  end

  def complete!(context, step_name, value, success: true, publish: true)
    storage.store_step_result(
      context.context_id, step_name,
      { "status" => "completed", "success" => success,
        "result" => RubyReactor::ContextSerializer.serialize_value(value) },
      "AsyncStepWaitSpecReactor"
    )
    storage.publish(RubyReactor.async_step_channel(context.context_id, step_name), "done") if publish
  end

  it "resolves work that finished BEFORE the reader ever subscribed" do
    context = context_with_ref
    complete!(context, :unit, { ok: true })

    expect(RubyReactor::Template::Result.new(:unit).resolve(context)).to eq({ ok: true })
  end

  it "resolves a completion for which no signal was ever published" do
    context = context_with_ref
    # Lands after the wait has begun, and stays silent — only the coarse
    # fallback re-check can find it.
    Thread.new do
      sleep 0.2
      complete!(context, :unit, :late, publish: false)
    end

    expect(RubyReactor::Template::Result.new(:unit).resolve(context)).to eq(:late)
  end

  it "hands the reader the Failure object when the unit failed" do
    context = context_with_ref
    complete!(context, :unit, { message: "boom" }, success: false)

    value = RubyReactor::Template::Result.new(:unit).resolve(context)
    expect(value).to be_a(RubyReactor::Failure)
    expect(value.error.to_s).to include("boom")
  end

  it "keeps waiting while the record is still `dispatched`" do
    context = context_with_ref
    storage.store_step_result(context.context_id, :unit, { "status" => "dispatched" },
                              "AsyncStepWaitSpecReactor")

    expect { RubyReactor::Template::Result.new(:unit).resolve(context) }
      .to raise_error(RubyReactor::Error::AsyncWaitTimeoutError)
  end

  it "does not wait at all for a step with no async reference" do
    context = RubyReactor::Context.new({}, Class.new(RubyReactor::Reactor))

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect(RubyReactor::Template::Result.new(:plain).resolve(context)).to be_nil
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.5
  end

  describe "in a reactor whose async step never completes" do
    for_each_async_backend do
      it "fails the reading step with a bounded timeout instead of hanging" do
        # Dispatched, never drained: the unit never reaches a terminal record.
        result = AsyncStepNeverCompletesReactor.run

        expect(result).to be_a(RubyReactor::Failure)
        expect(result.message).to match(/Timed out after 2s waiting for async completion/)
      end
    end
  end
end
