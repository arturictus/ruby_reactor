# frozen_string_literal: true

# Event log for the rollback specs (spec/ruby_reactor/rollback/), ported from
# the 007 evidence harness's `pstep`. Every recording step logs
# `run:<tag>.<name>[<i>]`, `compensate:…` and `undo:…`, so an example can
# assert a whole forward/rollback sequence at once:
#
#   class Elem < RollbackRecorder::Reactor
#     tag "e"
#     input :i
#     recording_step :e1, idx: true
#     recording_step :e2, after: :e1, idx: true, fail: ->(inputs) { inputs.i == 2 }
#   end
module RollbackRecorder
  @log = []
  @counters = Hash.new(0)

  class << self
    attr_reader :log, :counters

    def record(event)
      @log << event
    end

    def reset!
      @log.clear
      @counters.clear
    end

    def label(tag, name, index = nil)
      base = [tag, name].compact.join(".")
      index.nil? ? base : "#{base}[#{index}]"
    end

    # `fail:` is true, :raise, an Integer (fail the first N runs of this
    # label) or a `->(inputs) {}` predicate.
    def failing?(fail, lbl, inputs)
      case fail
      when Integer then (@counters[lbl] += 1) <= fail
      when Proc then fail.call(inputs)
      else fail
      end
    end
  end

  class Reactor < RubyReactor::Reactor
    def self.tag(value = nil)
      value ? @recording_tag = value : @recording_tag
    end

    # `undo_fails` / `compensate_raises` take true or a `->(inputs) {}`
    # predicate. `kind: :async_step` declares no `undo` (it is rejected there).
    # rubocop:disable Metrics/ParameterLists
    def self.recording_step(name, after: nil, fail: nil, idx: false, undo_fails: false, compensate_raises: false,
                            kind: :step, &extra)
      prefix = tag
      lbl = ->(inputs) { RollbackRecorder.label(prefix, name, idx ? inputs.i : nil) }
      hit = ->(flag, inputs) { flag.respond_to?(:call) ? flag.call(inputs) : flag }

      public_send(kind, name) do
        wait_for(*Array(after)) if after
        argument :i, input(:i) if idx
        run do |inputs, _ctx|
          RollbackRecorder.record("run:#{lbl.call(inputs)}")
          failing = RollbackRecorder.failing?(fail, lbl.call(inputs), inputs)
          raise "boom #{lbl.call(inputs)}" if failing && fail == :raise

          failing ? RubyReactor.Failure("boom #{lbl.call(inputs)}") : RubyReactor.Success("#{lbl.call(inputs)}-value")
        end
        compensate do |_error, inputs, _ctx|
          RollbackRecorder.record("compensate:#{lbl.call(inputs)}")
          raise "compensate #{lbl.call(inputs)} raised" if hit.call(compensate_raises, inputs)

          RubyReactor.Success()
        end
        unless kind == :async_step
          undo do |_value, inputs, _ctx|
            RollbackRecorder.record("undo:#{lbl.call(inputs)}")
            next RubyReactor.Success() unless hit.call(undo_fails, inputs)

            RubyReactor.Failure("undo #{lbl.call(inputs)} failed")
          end
        end
        instance_eval(&extra) if extra
      end
    end
    # rubocop:enable Metrics/ParameterLists
  end
end

RSpec.configure do |config|
  config.before(file_path: %r{spec/ruby_reactor/rollback/}) { RollbackRecorder.reset! }
end
