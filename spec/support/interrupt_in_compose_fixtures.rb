# frozen_string_literal: true

require_relative "rollback_recorder"

# 010: reactors that pause at an `interrupt` inside a composed child. Built on
# RollbackRecorder, so a spec can assert the whole forward/rollback sequence.
# The child's interrupt correlates on its `seed`, which the root feeds from
# `r1` ("r1-value").
module InterruptInComposeFixtures
  class << self
    # Called from the child's `c2` with its context, so a spec can act from
    # inside a running resume.
    attr_accessor :on_c2
  end

  def self.child(name, resume: :inline, second_interrupt: false, &interrupt_body)
    klass = Class.new(RollbackRecorder::Reactor) do
      tag "child"
      input :seed, optional: true
      recording_step :c1
      interrupt :approve, resume: resume do
        wait_for :c1
        correlation_id { |ctx| "approve-#{ctx.inputs[:seed]}" }
        instance_eval(&interrupt_body) if interrupt_body
      end
      interrupt(:sign) { wait_for :approve } if second_interrupt
      # Records the payload it received, so a resume can be seen to deliver it.
      step :c2 do
        argument :decision, result(:approve)
        wait_for :sign if second_interrupt
        run do |args, ctx|
          RollbackRecorder.record("run:child.c2")
          InterruptInComposeFixtures.on_c2&.call(ctx)
          RubyReactor.Success(args.decision)
        end
        undo do |_value, _args, _ctx|
          RollbackRecorder.record("undo:child.c2")
          RubyReactor.Success()
        end
      end
    end
    const_set(name, klass)
  end

  def self.root(name, composed, at: :fulfil, label: nil, own_interrupt: false, locked: false) # rubocop:disable Metrics/ParameterLists
    klass = Class.new(RollbackRecorder::Reactor) do
      tag(label) if label
      with_lock { |_inputs| "interrupt-in-compose:locked" } if locked
      input :seed, optional: true
      recording_step :r1
      compose(at, composed) { argument :seed, result(:r1) }
      # Declared after the compose, so the child pauses first and both are pending.
      interrupt(:audit) { wait_for :r1 } if own_interrupt
      recording_step :r2, after: own_interrupt ? [at, :audit] : at
    end
    const_set(name, klass)
  end

  child :Child
  root :Root, Child
  root :Middle, Child, label: "middle"
  root :Top, Middle, at: :order
  child :TwoInterruptsChild, second_interrupt: true
  root :TwoInterruptsRoot, TwoInterruptsChild
  root :RootWithOwnInterrupt, Child, own_interrupt: true
  root :LockedRoot, Child, locked: true
  child :BackgroundChild, resume: :background
  root :BackgroundRoot, BackgroundChild
  child(:ValidatedChild) { validate_payload { required(:ok).filled(:bool) } }
  root :ValidatedRoot, ValidatedChild
  child(:ValidatedRetryChild) do
    validate_payload { required(:ok).filled(:bool) }
    max_attempts 3
  end
  root :ValidatedRetryRoot, ValidatedRetryChild

  # An interrupt inside a map element, directly or through a compose, is
  # unsupported: the element fails (010 R-08).
  DirectElement = Class.new(RollbackRecorder::Reactor) do
    input :i
    recording_step :e1, idx: true
    interrupt(:approve) { wait_for :e1 }
  end
  ComposedElement = Class.new(RollbackRecorder::Reactor) do
    input :i
    compose :inner, InterruptInComposeFixtures::Child
  end

  def self.mapping(name, element, distributed: false)
    klass = Class.new(RollbackRecorder::Reactor) do
      input :items
      map :m, element do
        source input(:items)
        argument :i, element(:m)
        fan_out(batch_size: 1) if distributed
      end
    end
    const_set(name, klass)
  end

  mapping :InlineDirectMap, DirectElement
  mapping :InlineComposedMap, ComposedElement
  mapping :FanOutComposedMap, ComposedElement, distributed: true
end
