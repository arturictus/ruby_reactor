# frozen_string_literal: true

require "spec_helper"

# 011 R-09, FR-019, API §2: configurations in which a hop could not keep every
# guarantee are rejected before the first run, never run weaker.
RSpec.describe "queue configurations rejected at definition time" do
  def reactor(name, &block)
    klass = Class.new(RubyReactor::Reactor)
    stub_const(name, klass)
    klass.class_eval(&block)
    klass
  end

  def step_class(queue_name)
    Class.new(RubyReactor::Step) do
      queue queue_name
      def run = Success()
    end
  end

  let(:ledger_step) { step_class(:ledger) }
  let(:noop) { ->(_inputs, _ctx) { RubyReactor.Success() } }

  def element(name, queue_name: nil, &block)
    reactor(name) do
      queue queue_name if queue_name
      input :i
      class_eval(&block)
    end
  end

  def owner(name, element_class, fan: true)
    reactor(name) do
      input :items
      map :deposits, element_class do
        source input(:items)
        argument :i, element(:deposits)
        fan_out if fan
      end
    end
  end

  describe "a hop inside a map element" do
    it "rejects a step on another queue inside a fan-out element" do
      impl = ledger_step
      elem = element("RejElement", queue_name: :deposits) { step :notify, impl }

      expect { owner("RejFanOut", elem).validate_definition! }
        .to raise_error(RubyReactor::Error::ValidationError,
                        /RejFanOut map :deposits.*step :notify.*:ledger.*RejElement.*:deposits.*cannot hop/m)
    end

    it "rejects the same inside an inline element" do
      impl = ledger_step
      elem = element("RejInlineElement", queue_name: :deposits) { step :notify, impl }

      expect { owner("RejInline", elem, fan: false).validate_definition! }
        .to raise_error(RubyReactor::Error::ValidationError, /RejInline map :deposits.*cannot hop/m)
    end

    it "rejects any declaration inside an element reactor that declares none" do
      impl = ledger_step
      elem = element("RejPlainElement") { step :notify, impl }

      expect { owner("RejPlain", elem).validate_definition! }
        .to raise_error(RubyReactor::Error::ValidationError, /its container's queue/)
    end

    it "rejects a compose or a nested map on another queue inside an element" do
      inner = reactor("RejInnerChild") do
        queue :ledger
        step(:c) { run { |_i, _c| RubyReactor.Success() } }
      end
      composing = element("RejComposingElement", queue_name: :deposits) { compose :child, inner }
      expect { owner("RejCompose", composing).validate_definition! }
        .to raise_error(RubyReactor::Error::ValidationError, /compose :child.*:ledger/m)

      nested_element = reactor("RejNestedElement") do
        queue :ledger
        input :i
        step(:n) { run { |_i, _c| RubyReactor.Success() } }
      end
      nesting = element("RejNestingElement", queue_name: :deposits) do
        map :inner, nested_element do
          source [1]
          argument :i, element(:inner)
        end
      end
      expect { owner("RejNested", nesting).validate_definition! }
        .to raise_error(RubyReactor::Error::ValidationError, /map :inner.*:ledger/m)
    end

    it "rejects a step inside a compose inside an element" do
      impl = ledger_step
      inner = reactor("RejDeepChild") { step :deep, impl }
      deep = element("RejDeepElement", queue_name: :deposits) { compose :child, inner }

      expect { owner("RejDeep", deep).validate_definition! }
        .to raise_error(RubyReactor::Error::ValidationError, /step :child\.deep.*:ledger/m)
    end

    it "allows async units on other queues, and units on the element's own queue" do
      impl = ledger_step
      same = step_class(:deposits)
      elem = element("OkElement", queue_name: :deposits) do
        async_step :notify, impl
        step :same, same
      end

      expect { owner("OkOwner", elem).validate_definition! }.not_to raise_error
    end
  end

  describe "a hop under an ordered lock" do
    it "rejects a step or a compose on another queue" do
      impl = ledger_step
      expect do
        reactor("RejOrdered") do
          queue :main
          with_ordered_lock(ttl: 30) { |_inputs| "rej-ordered" }
          step :charge, impl
        end.validate_definition!
      end.to raise_error(RubyReactor::Error::ValidationError, /RejOrdered.*with_ordered_lock.*step :charge.*:ledger/m)

      child = reactor("RejOrderedChild") do
        queue :stripe
        step(:c) { run { |_i, _c| RubyReactor.Success() } }
      end
      expect do
        reactor("RejOrderedCompose") do
          with_ordered_lock(ttl: 30) { |_inputs| "rej-ordered-compose" }
          compose :child, child
        end.validate_definition!
      end.to raise_error(RubyReactor::Error::ValidationError, /compose :child.*:stripe/m)
    end

    it "allows every unit on the reactor's own queue, and locks and semaphores with hops" do
      same = step_class(:main)
      expect do
        reactor("OkOrdered") do
          queue :main
          with_ordered_lock(ttl: 30) { |_inputs| "ok-ordered" }
          step :charge, same
        end.validate_definition!
      end.not_to raise_error

      expect { QueueFixtures::MainLocked.validate_definition! }.not_to raise_error
      expect { QueueFixtures::MainSemaphore.validate_definition! }.not_to raise_error
    end
  end
end
