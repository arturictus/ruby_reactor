# frozen_string_literal: true

require_relative "rollback_recorder"

# Shared reactors for the 009 map rollback specs. `parent` builds the same
# reactor with an inline or a fan-out map, so a spec can run both and compare
# them (the oracle, contracts/rollback-protocol.md I-7):
#
#   MapRollbackFixtures.parent(MySpec, :Later, MapRollbackFixtures::ElemOk, fan_out: true, b_fails: true)
#   MySpec::Later.run(items: (0...20).to_a)
module MapRollbackFixtures
  # Indexes whose e1 undo already raised once (ElemInterruptOnce).
  def self.interrupted
    @interrupted ||= Set.new
  end

  class Elem < RollbackRecorder::Reactor
    tag "e"
    input :i
    input :fail_at, optional: true
    recording_step :e1, idx: true
    recording_step :e2, after: :e1, idx: true, fail: ->(inputs) { inputs.i == inputs.fail_at } do
      argument :fail_at, input(:fail_at)
    end
  end

  class ElemOk < RollbackRecorder::Reactor
    tag "e"
    input :i
    input :fail_at, optional: true
    recording_step :e1, idx: true
    recording_step :e2, after: :e1, idx: true
  end

  class ElemUndoFails < RollbackRecorder::Reactor
    tag "e"
    input :i
    input :fail_at, optional: true
    recording_step :e1, idx: true, undo_fails: ->(inputs) { inputs.i == 1 }
    recording_step :e2, after: :e1, idx: true
  end

  # e1's undo raises `Interrupt` the first time it runs for element 0, as a
  # worker killed mid-rollback would, and succeeds on the redelivery.
  class ElemInterruptOnce < RollbackRecorder::Reactor
    tag "e"
    input :i
    input :fail_at, optional: true
    recording_step :e1, idx: true do
      undo do |_value, inputs, _ctx|
        RollbackRecorder.record("undo:e.e1[#{inputs.i}]")
        raise Interrupt if inputs.i.zero? && MapRollbackFixtures.interrupted.add?(0)

        RubyReactor.Success()
      end
    end
    recording_step :e2, after: :e1, idx: true
  end

  # `a` → map `m` → `b`, with `m` inline or fan-out.
  # rubocop:disable Metrics/ParameterLists
  def self.parent(namespace, name, element_class, fan_out: false, batch_size: nil, b_fails: false, atomic: true,
                  collect: nil, undo_all: nil)
    distributed = fan_out
    size = batch_size
    collector = collect
    policy = atomic
    bulk = undo_all
    klass = Class.new(RollbackRecorder::Reactor) do
      input :items
      input :fail_at, optional: true
      recording_step :a
      map :m, element_class do
        source input(:items)
        argument :i, element(:m)
        argument :fail_at, input(:fail_at)
        atomic(policy)
        fan_out(batch_size: size) if distributed
        collect(&collector) if collector
        undo_all(&bulk) if bulk
      end
      recording_step :b, after: :m, fail: b_fails
    end
    namespace.const_set(name, klass)
  end
  # rubocop:enable Metrics/ParameterLists
end

RSpec.configure do |config|
  config.before { MapRollbackFixtures.interrupted.clear }
end
