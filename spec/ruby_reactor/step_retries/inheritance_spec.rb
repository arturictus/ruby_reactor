# frozen_string_literal: true

require "spec_helper"

# US6: subclasses inherit a step class's policy and can override it without
# touching the parent or siblings (FR-010).
RSpec.describe "Step retries: step subclasses" do
  let(:calls) { [] }
  let(:base) do
    log = calls
    Class.new(RubyReactor::Step) do
      retries max_attempts: 4, backoff: :fixed, base_delay: 0

      define_method(:run) do
        log << self.class
        Failure("x")
      end
    end
  end

  def attempts_in_reactor(step_class)
    reactor = Class.new(RubyReactor::Reactor) { step :s, step_class }.new
    reactor.run({})
    reactor.context.retry_context.attempts_for_step(:s)
  end

  it "inherits the parent's policy when the subclass declares none" do
    child = Class.new(base)

    expect(child.retry_config).to eq(base.retry_config)
    expect(attempts_in_reactor(child)).to eq(4)
  end

  it "lets a subclass override without affecting its parent or siblings" do
    overriding = Class.new(base) { retries max_attempts: 2, backoff: :fixed, base_delay: 0 }
    sibling = Class.new(base)

    expect(attempts_in_reactor(overriding)).to eq(2)
    expect(attempts_in_reactor(base)).to eq(4)
    expect(attempts_in_reactor(sibling)).to eq(4)
  end

  it "varies the policy per workflow through a subclass, with no conflict" do
    shared = base
    per_workflow = Class.new(shared) { retries max_attempts: 2, backoff: :fixed, base_delay: 0 }
    reactor_a = Class.new(RubyReactor::Reactor) { step :s, shared }
    reactor_b = Class.new(RubyReactor::Reactor) { step :s, per_workflow }

    expect(reactor_a.steps[:s].retry_config[:max_attempts]).to eq(4)
    expect(reactor_b.steps[:s].retry_config[:max_attempts]).to eq(2)
  end

  it "still inherits locks and the input contract alongside `retries`" do
    parent = Class.new(RubyReactor::Step) do
      input :card, :string
      with_lock { |inputs| "card:#{inputs[:card]}" }
      retries max_attempts: 3
    end
    child = Class.new(parent)

    expect(child.retry_config[:max_attempts]).to eq(3)
    expect(child.lock_config).not_to be_nil
    expect(child.declares_inputs?).to be(true)
  end
end
