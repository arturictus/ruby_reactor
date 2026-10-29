# frozen_string_literal: true

require "spec_helper"

RSpec.describe "queue resolution" do
  let(:queues) { RubyReactor::Queues }
  let(:declared) { reactor("Declared") { queue :stripe } }
  let(:undeclared) { reactor("Undeclared") }

  def reactor(name = "ResReactor", &block)
    Class.new(RubyReactor::Reactor) do
      define_singleton_method(:name) { name }
      class_eval(&block) if block
    end
  end

  def step_class(queue_name = nil)
    Class.new(RubyReactor::Step) do
      queue queue_name if queue_name
      def run = Success()
    end
  end

  def linked(child_class, parent)
    RubyReactor::Context.new({}, child_class).tap do |child|
      child.parent_context = parent
      child.root_context = parent.root_context || parent
    end
  end

  around do |example|
    original = RubyReactor.configuration.queue_name
    example.run
  ensure
    RubyReactor.configuration.queue_name = original
  end

  describe ".of_context" do
    it "is the reactor's declaration, else the global queue read at call time" do
      expect(queues.of_context(RubyReactor::Context.new({}, declared))).to eq("stripe")

      context = RubyReactor::Context.new({}, undeclared)
      expect(queues.of_context(context)).to eq("default")
      RubyReactor.configuration.queue_name = :critical
      expect(queues.of_context(context)).to eq("critical")
    end

    it "lets an undeclared composed child inherit its container's queue" do
      parent = RubyReactor::Context.new({}, declared)
      expect(queues.of_context(linked(undeclared, parent))).to eq("stripe")
      expect(queues.of_context(linked(reactor { queue :own }, parent))).to eq("own")
    end

    it "uses an inherited queue for an unlinked root (async_reactor child, fan-out element)" do
      context = RubyReactor::Context.new({}, undeclared)
      context.private_data["inherited_queue"] = "q"
      expect(queues.of_context(context)).to eq("q")
    end
  end

  describe ".node_queue and .dispatch_queue" do
    let(:owner) do
      impl = step_class(:ledger)
      kid = reactor("Child") { queue :child }
      plain = reactor("PlainChild") { step(:c) { run { |_i, _c| RubyReactor.Success() } } }
      reactor("Owner") do
        queue :main
        step :plain, impl
        step(:blocked, impl) { queue :block }
        step(:inline) { run { |_i, _c| RubyReactor.Success() } }
        compose :composed, kid
        compose :plain_composed, plain
        map(:inline_map, kid) { source [1] }
        map(:fan_map, kid) do
          source [1]
          fan_out
        end
        async_step :async, impl
        async_step(:async_inline) { run { |_i, _c| RubyReactor.Success() } }
        async_reactor :child_run, kid
        async_reactor :plain_run, plain
        interrupt :wait
      end
    end
    let(:context) { RubyReactor::Context.new({}, owner) }

    def node(name) = queues.node_queue(owner.steps[name], context)
    def dispatch(name) = queues.dispatch_queue(owner.steps[name], context)

    it "places each graph node on the queue of the job that runs it" do
      expect(node(:plain)).to eq("ledger")
      expect(node(:blocked)).to eq("block")
      expect(node(:inline)).to eq("main")
      expect(node(:composed)).to eq("child")
      expect(node(:plain_composed)).to eq("main")
      expect(node(:inline_map)).to eq("child")
      expect(%i[fan_map async async_inline child_run plain_run wait].map { |n| node(n) }).to all(eq("main"))
    end

    it "places a dispatched unit's own jobs" do
      expect(dispatch(:async)).to eq("ledger")
      expect(dispatch(:async_inline)).to eq("main")
      expect(dispatch(:child_run)).to eq("child")
      expect(dispatch(:plain_run)).to eq("main")
      expect(dispatch(:fan_map)).to eq("child")
    end
  end

  describe ".current" do
    it "reads the root's current_queue from any depth, nil when unset" do
      root = RubyReactor::Context.new({}, declared)
      child = linked(undeclared, root)
      expect(queues.current(child)).to be_nil

      root.current_queue = "stripe"
      expect(queues.current(child)).to eq("stripe")
    end
  end

  describe ".kwargs" do
    it "omits the queue when it is the global one" do
      expect(queues.kwargs("default")).to eq({})
      expect(queues.kwargs(nil)).to eq({})
      expect(queues.kwargs("stripe")).to eq(queue: "stripe")
      expect(queues.kwargs(:stripe)).to eq(queue: "stripe")
    end
  end

  describe ".declares_any?" do
    it "looks at the reactor, its plain steps and its compose/map children, not its async units" do
      impl = step_class(:ledger)
      kid = reactor("DeclaredKid") { queue :kid }
      plain = reactor("PlainKid") { step(:c) { run { |_i, _c| RubyReactor.Success() } } }

      expect(queues.declares_any?(reactor { queue :x })).to be(true)
      expect(queues.declares_any?(reactor { step :a, impl })).to be(true)
      expect(queues.declares_any?(reactor { step(:a) { queue :b } })).to be(true)
      expect(queues.declares_any?(reactor { compose :c, kid })).to be(true)
      expect(queues.declares_any?(reactor { map(:m, kid) { source [1] } })).to be(true)
      expect(queues.declares_any?(reactor { async_step :a, impl })).to be(false)
      expect(queues.declares_any?(reactor { async_reactor :a, kid })).to be(false)
      expect(queues.declares_any?(reactor { compose :c, plain })).to be(false)
    end
  end

  describe "trace stamping" do
    it "stamps the job's queue on trace entries written in a job" do
      root = RubyReactor::Context.new({}, declared)
      child = linked(undeclared, root)

      child.append_execution_trace({ type: :run, step: :a })
      expect(child.execution_trace.last).not_to have_key(:queue)

      root.current_queue = "stripe"
      child.append_execution_trace({ type: :run, step: :b })
      expect(child.execution_trace.last[:queue]).to eq("stripe")
    end

    it "never serializes current_queue" do
      context = RubyReactor::Context.new({}, declared)
      context.current_queue = "stripe"
      restored = RubyReactor::ContextSerializer.deserialize(RubyReactor::ContextSerializer.serialize(context))
      expect(restored.current_queue).to be_nil
    end
  end
end
