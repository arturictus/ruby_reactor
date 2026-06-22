# frozen_string_literal: true

require "spec_helper"
require "opentelemetry-sdk"
require "sidekiq/testing"

# Define inline test steps and reactors
class TelemetrySimpleStep
  def self.run(arguments, _context)
    RubyReactor.Success(arguments[:value].to_i * 2)
  end
end

class TelemetrySensitiveStep
  def self.run(_arguments, _context)
    RubyReactor.Success("ok")
  end
end

class TelemetrySimpleReactor < RubyReactor::Reactor
  input :input_val
  input :secret_input, redact: true, optional: true

  step :double_it, TelemetrySimpleStep do
    argument :value, input(:input_val)
  end

  returns :double_it
end

class TelemetryLockReactor < RubyReactor::Reactor
  input :user_id
  with_lock(ttl: 10) { |inputs| "user:#{inputs[:user_id]}" }

  step :do_work do
    run do |_inputs|
      RubyReactor.Success("done")
    end
  end
end

class TelemetrySemaphoreReactor < RubyReactor::Reactor
  input :resource_id
  with_semaphore(limit: 2, wait: 0) { |inputs| "sem:#{inputs[:resource_id]}" }

  step :do_work do
    run do |_inputs|
      RubyReactor.Success("done")
    end
  end
end

class TelemetryFlakyStep
  @attempts = 0
  class << self
    attr_accessor :attempts

    def run(_arguments, _context)
      @attempts += 1
      raise "transient error" if @attempts < 3

      RubyReactor.Success("success after retries")
    end
  end
end

class TelemetryRetryReactor < RubyReactor::Reactor
  step :flaky, TelemetryFlakyStep do
    retries max_attempts: 3, base_delay: 0
  end
end

class TelemetryAsyncRetryStep
  @attempts = 0
  class << self
    attr_accessor :attempts

    def run(_arguments, _context)
      @attempts += 1
      return RubyReactor.Failure("transient async error") if @attempts < 2

      RubyReactor.Success("async success after retry")
    end
  end
end

class TelemetryAsyncRetryReactor < RubyReactor::Reactor
  step :flaky_async, TelemetryAsyncRetryStep do
    async true
    retries max_attempts: 3, base_delay: 0
  end
end

class TelemetryInnerReactor < RubyReactor::Reactor
  step :inner_step do
    run do |_inputs|
      RubyReactor.Success("inner_val")
    end
  end
end

class TelemetryOuterReactor < RubyReactor::Reactor
  compose :inner, TelemetryInnerReactor
end

class TelemetryMapElementReactor < RubyReactor::Reactor
  input :item
  step :process_item do
    run do |inputs|
      RubyReactor.Success(inputs[:item].to_i * 2)
    end
  end
end

class TelemetryMapReactor < RubyReactor::Reactor
  input :items
  map :process_items, TelemetryMapElementReactor do
    source input(:items)
    argument :item, element(:process_items)
  end
end

class TelemetryMapFailElement < RubyReactor::Reactor
  input :item
  step :boom do
    run { RubyReactor.Failure("map element boom") }
  end
end

class TelemetryAsyncMapRollbackReactor < RubyReactor::Reactor
  input :items
  step :prep do
    run { RubyReactor.Success("prepared") }
    undo { |_result, _args, _context| RubyReactor.Success("prep undone") }
  end
  map :failing_map, TelemetryMapFailElement do
    async true
    source input(:items)
    argument :item, element(:failing_map)
  end
end

class TelemetryAsyncStepReactor < RubyReactor::Reactor
  input :value
  step :async_step do
    async true
    run do |args, _context|
      RubyReactor.Success(args[:value].to_i + 10)
    end
  end
end

class TelemetryInlineCompensateReactor < RubyReactor::Reactor
  step :failing_step do
    run { raise "step failed" }
    compensate { |_error, _arguments, _context| RubyReactor.Success("compensated inline") }
  end
end

class TelemetryInlineUndoReactor < RubyReactor::Reactor
  step :first_step do
    run { RubyReactor.Success(42) }
    undo { |_result, _arguments, _context| RubyReactor.Success("undone inline") }
  end
  step :second_step do
    run { raise "force rollback" }
  end
end

class TelemetryFailingCompensateReactor < RubyReactor::Reactor
  step :failing_step do
    run { raise "step failed" }
    compensate { |_error, _arguments, _context| raise "compensation failed" }
  end
end

class TelemetryFailingUndoReactor < RubyReactor::Reactor
  step :first_step do
    run { RubyReactor.Success(42) }
    undo { |_result, _arguments, _context| raise "undo failed" }
  end
  step :second_step do
    run { raise "force rollback" }
  end
end

# Element whose step fails on early attempts (tracked via retry_context so it
# survives async requeues) and then succeeds.
class TelemetryAsyncMapRetryElement < RubyReactor::Reactor
  input :item
  input :fail_until
  step :el_step do
    argument :val, input(:item)
    argument :fail_until, input(:fail_until)
    retries max_attempts: 5, base_delay: 0
    run do |args, context|
      attempt = context.retry_context.attempts_for_step(:el_step)
      if attempt < args[:fail_until]
        RubyReactor.Failure("map element attempt #{attempt} failed")
      else
        RubyReactor.Success(args[:val].to_i * 10)
      end
    end
  end
  returns :el_step
end

class TelemetryAsyncMapRetryReactor < RubyReactor::Reactor
  input :items
  input :fail_until_attempt
  map :mapped, TelemetryAsyncMapRetryElement do
    source input(:items)
    argument :item, element(:mapped)
    argument :fail_until, input(:fail_until_attempt)
    async true, batch_size: 1
  end
end

RSpec.describe "RubyReactor OpenTelemetry Tracing" do
  let(:provider) { OpenTelemetry::SDK::Trace::TracerProvider.new }
  let(:exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }
  let(:processor) { OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter) }

  before do
    provider.add_span_processor(processor)
    allow(OpenTelemetry).to receive_messages(tracer_provider: provider, propagation: OpenTelemetry::Trace::Propagation::TraceContext.text_map_propagator)

    RubyReactor.configure do |config|
      config.middlewares = [RubyReactor::OpenTelemetry]
    end
  end

  after do
    RubyReactor.configure do |config|
      config.middlewares = []
    end
  end

  describe "Core Tracing and Span Nesting" do
    it "perfectly nests step spans under the reactor span" do
      reactor = TelemetrySimpleReactor.new
      result = reactor.run(input_val: 10)

      expect(result.value).to eq(20)

      spans = exporter.finished_spans
      expect(spans.size).to eq(2)

      step_span = spans.find { |s| s.name == "step.double_it" }
      reactor_span = spans.find { |s| s.name == "TelemetrySimpleReactor" }

      expect(step_span).not_to be_nil
      expect(reactor_span).not_to be_nil
      expect(step_span.parent_span_id).to eq(reactor_span.span_id)
    end

    it "includes reactor name, context_id, and safely records arguments" do
      reactor = TelemetrySimpleReactor.new
      reactor.run(input_val: 42)

      spans = exporter.finished_spans
      reactor_span = spans.find { |s| s.name == "TelemetrySimpleReactor" }
      step_span = spans.find { |s| s.name == "step.double_it" }

      # Core attributes
      expect(reactor_span.attributes["reactor.name"]).to eq("TelemetrySimpleReactor")
      expect(reactor_span.attributes["reactor.context_id"]).to eq(reactor.context.context_id)

      # Dynamic argument/input recording
      expect(reactor_span.attributes["reactor.inputs.input_val"]).to eq("42")
      expect(step_span.attributes["step.arguments.value"]).to eq("42")
    end
  end

  describe "Argument Safety & Redaction" do
    it "redacts sensitive input fields based on redact: true" do
      reactor = TelemetrySimpleReactor.new
      reactor.run(input_val: 5, secret_input: "super_secret_password")

      spans = exporter.finished_spans
      reactor_span = spans.find { |s| s.name == "TelemetrySimpleReactor" }

      expect(reactor_span.attributes["reactor.inputs.secret_input"]).to eq("[REDACTED]")
    end

    it "safely truncates massive argument values to 256 characters" do
      huge_str = "a" * 300
      reactor = TelemetrySimpleReactor.new
      reactor.run(input_val: huge_str)

      spans = exporter.finished_spans
      reactor_span = spans.find { |s| s.name == "TelemetrySimpleReactor" }
      step_span = spans.find { |s| s.name == "step.double_it" }

      truncated_val = reactor_span.attributes["reactor.inputs.input_val"]
      expect(truncated_val).to end_with("... [truncated]")
      expect(truncated_val.length).to be <= 256

      truncated_arg = step_span.attributes["step.arguments.value"]
      expect(truncated_arg).to end_with("... [truncated]")
      expect(truncated_arg.length).to be <= 256
    end
  end

  describe "Lock & Semaphore Telemetry Events" do
    it "records lock acquisition, key, and release events" do
      reactor = TelemetryLockReactor.new
      reactor.run(user_id: "user123")

      spans = exporter.finished_spans
      reactor_span = spans.find { |s| s.name == "TelemetryLockReactor" }

      expect(reactor_span.attributes["reactor.lock.key"]).to eq("user:user123")

      events = reactor_span.events
      expect(events.map(&:name)).to include("lock_acquired", "lock_released")
      expect(events.find { |e| e.name == "lock_acquired" }.attributes["lock.key"]).to eq("user:user123")
      # Release event uses the Lock object's key which has the 'lock:' prefix
      expect(events.find { |e| e.name == "lock_released" }.attributes["lock.key"]).to eq("lock:user:user123")
    end

    it "records semaphore key, limit, and acquisition/release events" do
      reactor = TelemetrySemaphoreReactor.new
      reactor.run(resource_id: "resource456")

      spans = exporter.finished_spans
      reactor_span = spans.find { |s| s.name == "TelemetrySemaphoreReactor" }

      expect(reactor_span.attributes["reactor.semaphore.key"]).to eq("sem:resource456")
      expect(reactor_span.attributes["reactor.semaphore.limit"]).to eq(2)

      events = reactor_span.events
      expect(events.map(&:name)).to include("semaphore_acquired", "semaphore_released")
      expect(events.find { |e| e.name == "semaphore_acquired" }.attributes["semaphore.key"]).to eq("sem:resource456")
      # Release event uses the Semaphore object's key which has the 'semaphore:' prefix
      expect(events.find do |e|
        e.name == "semaphore_released"
      end.attributes["semaphore.key"]).to eq("semaphore:sem:resource456")
    end
  end

  describe "Retry Telemetry Span Events" do
    it "logs retry attempts as Span Events on the step span" do
      TelemetryFlakyStep.attempts = 0
      reactor = TelemetryRetryReactor.new
      reactor.run

      spans = exporter.finished_spans
      step_span = spans.find { |s| s.name == "step.flaky" }
      expect(step_span).not_to be_nil

      events = step_span.events.select { |e| e.name == "retry_attempt" }
      expect(events.size).to eq(2)

      expect(events[0].attributes["attempt"]).to eq(1)
      expect(events[0].attributes["error.message"]).to eq("transient error")
      expect(events[0].attributes["error.class"]).to eq("RuntimeError")

      expect(events[1].attributes["attempt"]).to eq(2)
      expect(events[1].attributes["error.message"]).to eq("transient error")
      expect(events[1].attributes["error.class"]).to eq("RuntimeError")
    end
  end

  describe "Async Retry Telemetry" do
    it "marks a failed-but-requeued attempt span as ERROR without failing the reactor span" do
      TelemetryAsyncRetryStep.attempts = 0

      Sidekiq::Testing.inline! do
        TelemetryAsyncRetryReactor.new.run(value: 1)
      end

      spans = exporter.finished_spans
      flaky_spans = spans.select { |s| s.name == "step.flaky_async" }

      # The attempt that failed and was requeued is recorded as an error span,
      # annotated as a retry. OTel span status does not propagate, so this does
      # not fail the reactor span.
      requeued = flaky_spans.find { |s| s.attributes["step.status"] == "failed_will_retry" }
      expect(requeued).not_to be_nil
      expect(requeued.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
      expect(requeued.attributes["retry.will_retry"]).to be(true)
      expect(requeued.attributes["error.message"]).to eq("transient async error")

      # The retried attempt eventually succeeds.
      succeeded = flaky_spans.find { |s| s.attributes["step.status"] == "completed" }
      expect(succeeded).not_to be_nil
      expect(succeeded.status.code).to eq(OpenTelemetry::Trace::Status::OK)

      # The reactor as a whole succeeds despite the transient failure.
      reactor_spans = spans.select { |s| s.name == "TelemetryAsyncRetryReactor" }
      expect(reactor_spans).not_to be_empty
      reactor_spans.each do |rs|
        expect(rs.status.code).not_to eq(OpenTelemetry::Trace::Status::ERROR)
      end
    end

    # Under real async execution (fake! + drain, i.e. how production Sidekiq
    # behaves) the worker attempt that requeues the step finishes its executor
    # with a RetryQueuedResult, so on_complete_reactor receives it. (Under
    # inline! the requeue runs synchronously and collapses to Success, which is
    # why the test above does not exercise this path.)
    it "marks the reactor span of a requeued attempt as ERROR while the final attempt stays OK" do
      TelemetryAsyncRetryStep.attempts = 0

      TelemetryAsyncRetryReactor.new.run
      5.times do
        RubyReactor::Adapters::Sidekiq::Worker.drain
        break if RubyReactor::Adapters::Sidekiq::Worker.jobs.empty?
      end

      spans = exporter.finished_spans
      reactor_spans = spans.select { |s| s.name == "TelemetryAsyncRetryReactor" }

      requeued = reactor_spans.find { |s| s.attributes["reactor.status"] == "failed_will_retry" }
      expect(requeued).not_to be_nil
      expect(requeued.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
      expect(requeued.attributes["retry.will_retry"]).to be(true)
      expect(requeued.attributes["retry.step_name"]).to eq("flaky_async")

      completed = reactor_spans.find { |s| s.attributes["reactor.status"] == "completed" }
      expect(completed).not_to be_nil
      expect(completed.status.code).to eq(OpenTelemetry::Trace::Status::OK)
    end
  end

  describe "Async Map Element Retry Telemetry" do
    it "traces a requeued async map element attempt as ERROR and the successful attempt as OK" do
      TelemetryAsyncMapRetryReactor.new.run(items: [3], fail_until_attempt: 2)
      8.times do
        RubyReactor::Adapters::Sidekiq::MapElementWorker.drain
        RubyReactor::Adapters::Sidekiq::MapCollectorWorker.drain
        break if RubyReactor::Adapters::Sidekiq::MapElementWorker.jobs.empty? &&
                 RubyReactor::Adapters::Sidekiq::MapCollectorWorker.jobs.empty?
      end

      spans = exporter.finished_spans

      # The element step span for the failed-but-requeued attempt is marked ERROR
      # with the failed_will_retry annotation (same treatment as step-level async
      # retries).
      step_spans = spans.select { |s| s.name == "step.el_step" }
      requeued_step = step_spans.find { |s| s.attributes["step.status"] == "failed_will_retry" }
      expect(requeued_step).not_to be_nil
      expect(requeued_step.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
      expect(requeued_step.attributes["retry.will_retry"]).to be(true)

      # The element reactor span for that requeued attempt is likewise ERROR /
      # failed_will_retry, since it represents a single failed attempt.
      element_spans = spans.select { |s| s.name == "TelemetryAsyncMapRetryElement" }
      requeued_element = element_spans.find { |s| s.attributes["reactor.status"] == "failed_will_retry" }
      expect(requeued_element).not_to be_nil
      expect(requeued_element.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
      expect(requeued_element.attributes["retry.will_retry"]).to be(true)

      # The retried attempt eventually succeeds; that element reactor span is OK.
      completed_element = element_spans.find { |s| s.attributes["reactor.status"] == "completed" }
      expect(completed_element).not_to be_nil
      expect(completed_element.status.code).to eq(OpenTelemetry::Trace::Status::OK)
    end
  end

  describe "Sync Composed Nesting" do
    it "perfectly nests outer step, inner reactor, and inner step spans" do
      reactor = TelemetryOuterReactor.new
      reactor.run

      spans = exporter.finished_spans
      outer_span = spans.find { |s| s.name == "TelemetryOuterReactor" }
      step_inner_span = spans.find { |s| s.name == "step.inner" }
      inner_reactor_span = spans.find { |s| s.name == "TelemetryInnerReactor" }
      inner_step_span = spans.find { |s| s.name == "step.inner_step" }

      expect(outer_span).not_to be_nil
      expect(step_inner_span).not_to be_nil
      expect(inner_reactor_span).not_to be_nil
      expect(inner_step_span).not_to be_nil

      expect(step_inner_span.parent_span_id).to eq(outer_span.span_id)
      expect(inner_reactor_span.parent_span_id).to eq(step_inner_span.span_id)
      expect(inner_step_span.parent_span_id).to eq(inner_reactor_span.span_id)
    end
  end

  describe "Map Step Nesting (Sync)" do
    it "perfectly nests element reactors under the map step span" do
      reactor = TelemetryMapReactor.new
      reactor.run(items: [1, 2])

      spans = exporter.finished_spans
      map_reactor_span = spans.find { |s| s.name == "TelemetryMapReactor" }
      map_step_span = spans.find { |s| s.name == "step.process_items" }
      element_spans = spans.select { |s| s.name == "TelemetryMapElementReactor" }
      element_step_spans = spans.select { |s| s.name == "step.process_item" }

      expect(map_reactor_span).not_to be_nil
      expect(map_step_span).not_to be_nil
      expect(map_step_span.parent_span_id).to eq(map_reactor_span.span_id)

      expect(element_spans.size).to eq(2)
      element_spans.each do |es|
        expect(es.parent_span_id).to eq(map_step_span.span_id)
      end

      expect(element_step_spans.size).to eq(2)
      element_step_spans.each_with_index do |ess, idx|
        expect(ess.parent_span_id).to eq(element_spans[idx].span_id)
      end
    end
  end

  describe "Sidekiq Distributed Context Propagation" do
    it "injects and extracts context to trace async steps inside workers" do
      Sidekiq::Testing.inline! do
        reactor = TelemetryAsyncStepReactor.new
        reactor.run(value: 5)

        spans = exporter.finished_spans
        reactor_spans = spans.select { |s| s.name == "TelemetryAsyncStepReactor" }
        expect(reactor_spans.size).to eq(2) # 1 for main thread, 1 for Sidekiq resume

        invalid_id = OpenTelemetry::Trace::INVALID_SPAN_ID
        main_reactor_span = reactor_spans.find { |s| s.parent_span_id == invalid_id }
        resumed_reactor_span = reactor_spans.find { |s| s.parent_span_id != invalid_id }

        expect(main_reactor_span).not_to be_nil
        expect(resumed_reactor_span).not_to be_nil

        # The main thread only hands the step off to the worker; that span is
        # renamed to "step.async_step.enqueue" and tagged as handed off. The
        # real execution happens once, on the Sidekiq thread, as "step.async_step".
        main_step = spans.find { |s| s.name == "step.async_step.enqueue" }
        sidekiq_step = spans.find { |s| s.name == "step.async_step" }

        expect(main_step).not_to be_nil
        expect(main_step.parent_span_id).to eq(main_reactor_span.span_id)
        expect(main_step.attributes["step.status"]).to eq("handed_off")
        expect(main_step.attributes["step.async"]).to be(true)

        expect(sidekiq_step).not_to be_nil
        expect(sidekiq_step.parent_span_id).to eq(resumed_reactor_span.span_id)

        # The resumed reactor span nests under the enqueue step span (not flattened
        # directly under the reactor), so the step that handed the work off reflects
        # the total execution time of the async work in the trace waterfall.
        expect(resumed_reactor_span.parent_span_id).to eq(main_step.span_id)
      end
    end
  end

  describe "Async Map Failure Rollback Nesting" do
    it "nests rollback undo spans under a reactor span instead of orphaning them" do
      Sidekiq::Testing.inline! do
        TelemetryAsyncMapRollbackReactor.new.run(items: [1, 2])
      end

      spans = exporter.finished_spans
      undo_span = spans.find { |s| s.name == "undo.prep" }
      expect(undo_span).not_to be_nil

      # The undo span must not be a root/orphan span.
      invalid_id = OpenTelemetry::Trace::INVALID_SPAN_ID
      expect(undo_span.parent_span_id).not_to eq(invalid_id)

      # Its parent must be one of the reactor spans (the rollback now runs under
      # a reactor span emitted by the map failure resume path).
      reactor_span_ids = spans.select { |s| s.name == "TelemetryAsyncMapRollbackReactor" }.map(&:span_id)
      expect(reactor_span_ids).to include(undo_span.parent_span_id)
    end
  end

  describe "Compensation and Undo Tracing" do
    it "traces successful compensations under the reactor span" do
      reactor = TelemetryInlineCompensateReactor.new
      reactor.run

      spans = exporter.finished_spans
      reactor_span = spans.find { |s| s.name == "TelemetryInlineCompensateReactor" }
      compensate_span = spans.find { |s| s.name == "compensate.failing_step" }

      expect(reactor_span).not_to be_nil
      expect(compensate_span).not_to be_nil
      expect(compensate_span.parent_span_id).to eq(reactor_span.span_id)
      expect(compensate_span.status.code).to eq(OpenTelemetry::Trace::Status::OK)
      expect(compensate_span.attributes["compensation.status"]).to eq("completed")
      expect(compensate_span.attributes["compensation.trigger_error.message"]).to eq("step failed")
    end

    it "traces failed compensations with error status" do
      reactor = TelemetryFailingCompensateReactor.new
      result = reactor.run
      expect(result).to be_a(RubyReactor::Failure)

      spans = exporter.finished_spans
      reactor_span = spans.find { |s| s.name == "TelemetryFailingCompensateReactor" }
      compensate_span = spans.find { |s| s.name == "compensate.failing_step" }

      expect(reactor_span).not_to be_nil
      expect(compensate_span).not_to be_nil
      expect(compensate_span.parent_span_id).to eq(reactor_span.span_id)
      expect(compensate_span.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
      expect(compensate_span.attributes["compensation.status"]).to eq("failed")
      expect(compensate_span.attributes["error.message"]).to eq("compensation failed")
    end

    it "traces successful undos under the reactor span during rollback" do
      reactor = TelemetryInlineUndoReactor.new
      reactor.run

      spans = exporter.finished_spans
      reactor_span = spans.find { |s| s.name == "TelemetryInlineUndoReactor" }
      undo_span = spans.find { |s| s.name == "undo.first_step" }

      expect(reactor_span).not_to be_nil
      expect(undo_span).not_to be_nil
      expect(undo_span.parent_span_id).to eq(reactor_span.span_id)
      expect(undo_span.status.code).to eq(OpenTelemetry::Trace::Status::OK)
      expect(undo_span.attributes["undo.status"]).to eq("completed")
      expect(undo_span.attributes["undo.original_result.value"]).to eq("42")
    end

    it "traces failed undos with error status during rollback" do
      reactor = TelemetryFailingUndoReactor.new
      reactor.run

      spans = exporter.finished_spans
      reactor_span = spans.find { |s| s.name == "TelemetryFailingUndoReactor" }
      undo_span = spans.find { |s| s.name == "undo.first_step" }

      expect(reactor_span).not_to be_nil
      expect(undo_span).not_to be_nil
      expect(undo_span.parent_span_id).to eq(reactor_span.span_id)
      expect(undo_span.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
      expect(undo_span.attributes["undo.status"]).to eq("failed")
      expect(undo_span.attributes["error.message"]).to eq("undo failed")
    end
  end
end
