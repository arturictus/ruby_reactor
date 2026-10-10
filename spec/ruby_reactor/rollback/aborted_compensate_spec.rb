# frozen_string_literal: true

require "spec_helper"
require "ruby_reactor/web/api"

# 010 US6 (FR-022–FR-026, R-10, J-9, P-5): an interruption during the failing
# step's own `compensate` leaves the run `aborted` with that compensate
# recorded; a manual undo runs it again, with the same arguments and reason,
# before the undo stack.
module AbortedCompensateSpec
  CRASH = Interrupt.new("deploy")

  def self.events
    @events ||= []
  end

  # `run` fails with a string reason, or raises with `raise_error`.
  # `compensate` is interrupted on its first call; on later calls it records
  # what it received, and fails when `compensate_fails` is set.
  class XStep < RubyReactor::Step
    input :id, :integer
    input :raise_error, optional: true
    input :compensate_fails, optional: true
    input :crash_compensate, optional: true

    def run
      raise ArgumentError, "bad id" if inputs.raise_error

      Failure("x failed")
    end

    def compensate
      RollbackRecorder.record("compensate-start:x")
      first = (RollbackRecorder.counters["x compensates"] += 1) == 1
      raise CRASH if first && inputs.crash_compensate != false

      message = reason.respond_to?(:message) ? reason.message : reason.to_s
      origin = reason.respond_to?(:original_class) ? reason.original_class : reason.class
      detail = "#{origin}:#{message}"
      RollbackRecorder.record("compensate:x(id=#{inputs.id},#{detail})")
      inputs.compensate_fails ? Failure("nope") : Success()
    end
  end

  class Probe < RubyReactor::Middleware
    def on_failed_compensation(step_name, *)
      AbortedCompensateSpec.events << [:failed_compensation, step_name]
    end
  end

  class Root < RollbackRecorder::Reactor
    middleware Probe
    input :raise_error, optional: true
    input :compensate_fails, optional: true
    input :crash_compensate, optional: true
    recording_step :a
    step :x, XStep do
      wait_for :a
      argument :id, value(7)
      argument :raise_error, input(:raise_error)
      argument :compensate_fails, input(:compensate_fails)
      argument :crash_compensate, input(:crash_compensate)
    end
  end

  # x's compensate returns; a's undo is interrupted on the first rollback.
  class UndoCrashes < RollbackRecorder::Reactor
    input :crash_compensate, optional: true
    recording_step(:a) do
      undo do |_value, _inputs, _ctx|
        RollbackRecorder.record("undo:a")
        raise CRASH if (RollbackRecorder.counters["a undos"] += 1) == 1

        RubyReactor.Success()
      end
    end
    step :x, XStep do
      wait_for :a
      argument :id, value(7)
      argument :crash_compensate, input(:crash_compensate)
    end
  end

  class Child < RollbackRecorder::Reactor
    tag "child"
    input :from_a
    recording_step :c1
    step :x, XStep do
      wait_for :c1
      argument :id, value(8)
    end
  end

  class ComposesChild < RollbackRecorder::Reactor
    recording_step :a
    compose(:child, Child) { argument :from_a, result(:a) }
  end

  # Every element fails at x; the first compensate is interrupted.
  class Element < RollbackRecorder::Reactor
    tag "e"
    input :i
    recording_step :e1, idx: true
    step :x, XStep do
      wait_for :e1
      argument :id, input(:i)
    end
  end

  class MapsElements < RollbackRecorder::Reactor
    input :items
    recording_step :a
    map :m, Element do
      source input(:items)
      argument :i, element(:m)
    end
  end
end

RSpec.describe "Manual undo re-runs a cut-off compensate (010 US6)" do
  include Rack::Test::Methods

  def app
    RubyReactor::Web::API
  end

  before { AbortedCompensateSpec.events.clear }

  def abort_run(klass, inputs = {})
    reactor = klass.new
    expect { reactor.run(inputs) }.to raise_error(Interrupt)
    reactor.context.context_id
  end

  def stored(klass, id)
    klass.find(id).context
  end

  let(:klass) { AbortedCompensateSpec::Root }

  it "records the step whose compensate was cut off, with its arguments and reason" do
    id = abort_run(klass)

    context = stored(klass, id)
    expect(context.status.to_s).to eq("aborted")
    record = context.rollback
    expect(record).to include("step" => "x", "compensated" => false, "error" => "x failed")
    expect(RubyReactor::ContextSerializer.deserialize_value(record["arguments"])).to include(id: 7)
  end

  it "runs that compensate again, with the same arguments and reason, before the undo stack" do
    id = abort_run(klass)

    klass.undo(id)

    expect(RollbackRecorder.log).to eq(
      ["run:a", "compensate-start:x", "compensate-start:x", "compensate:x(id=7,String:x failed)", "undo:a"]
    )
    context = stored(klass, id)
    expect(context.status.to_s).to eq("cancelled")
    expect(context.rollback).to be_nil
  end

  it "passes an exception reason as a RecordedFailure carrying the original class" do
    id = abort_run(klass, { raise_error: true })

    klass.undo(id)

    expect(RollbackRecorder.log).to include("compensate:x(id=7,ArgumentError:bad id)")
  end

  it "does not run a compensate that returned before the interruption" do
    id = abort_run(AbortedCompensateSpec::UndoCrashes, { crash_compensate: false })
    expect(stored(AbortedCompensateSpec::UndoCrashes, id).rollback.to_h).not_to have_key("arguments")
    RollbackRecorder.log.clear

    AbortedCompensateSpec::UndoCrashes.undo(id)

    expect(RollbackRecorder.log).to eq(%w[undo:a])
  end

  it "reports a re-run compensate that fails, and still undoes the completed steps" do
    id = abort_run(klass, { compensate_fails: true })

    klass.undo(id)

    expect(RollbackRecorder.log.last).to eq("undo:a")
    expect(AbortedCompensateSpec.events).to include(%i[failed_compensation x])
    trace = stored(klass, id).execution_trace
    entry = trace.reverse.find { |e| (e[:type] || e["type"]).to_s == "compensate" }
    expect(entry).not_to be_nil
  end

  it "re-runs a composed child's cut-off compensate before the child's undos, then the root's" do
    id = abort_run(AbortedCompensateSpec::ComposesChild)

    AbortedCompensateSpec::ComposesChild.undo(id)

    tail = RollbackRecorder.log.drop_while { |e| e != "compensate-start:x" }.drop(1)
    expect(tail).to eq(["compensate-start:x", "compensate:x(id=8,String:x failed)", "undo:child.c1", "undo:a"])
  end

  it "re-runs an inline map element's cut-off compensate before that element's undos" do
    id = abort_run(AbortedCompensateSpec::MapsElements, { items: [0, 1] })

    AbortedCompensateSpec::MapsElements.undo(id)

    # Element 0's x failed and its compensate was cut off; element 1 never started.
    expect(RollbackRecorder.log).to eq(
      ["run:a", "run:e.e1[0]", "compensate-start:x", "compensate-start:x", "compensate:x(id=0,String:x failed)",
       "undo:e.e1[0]", "undo:a"]
    )
  end

  describe "the dashboard API" do
    it "names the outstanding compensate on an aborted run, and drops it after undo" do
      id = abort_run(klass)

      get "/reactors/#{id}"
      expect(JSON.parse(last_response.body)["pending_compensation"]).to eq("step" => "x")

      klass.undo(id)
      get "/reactors/#{id}"
      expect(JSON.parse(last_response.body)).not_to have_key("pending_compensation")
    end

    it "shows nothing for an aborted run whose compensate had returned" do
      id = abort_run(AbortedCompensateSpec::UndoCrashes, { crash_compensate: false })

      get "/reactors/#{id}"
      expect(JSON.parse(last_response.body)).not_to have_key("pending_compensation")
    end
  end
end
