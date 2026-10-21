# frozen_string_literal: true

require "spec_helper"

RSpec.describe "queue declarations" do
  let(:frozen_message) { "Can not modify static configurations in the runtime" }

  def reactor(&block)
    Class.new(RubyReactor::Reactor) do
      define_singleton_method(:name) { "DeclReactor" }
      class_eval(&block) if block
    end
  end

  def step_class(&block)
    Class.new(RubyReactor::Step) do
      define_singleton_method(:name) { "DeclStep" }
      def run = Success()
      class_eval(&block) if block
    end
  end

  describe "declaring and reading" do
    it "reads a reactor's and a step class's declaration as a String" do
      expect(reactor { queue :x }.declared_queue).to eq("x")
      expect(step_class { queue "y" }.declared_queue).to eq("y")
      expect(reactor.declared_queue).to be_nil
    end

    it "accepts the same declaration twice and rejects a different one" do
      klass = reactor { queue :x }
      expect { klass.class_eval { queue :x } }.not_to raise_error

      expect { klass.class_eval { queue :y } }
        .to raise_error(RubyReactor::Error::ValidationError, /DeclReactor.*queue :x.*queue :y/)
      expect(klass.declared_queue).to eq("x")
    end

    it "rejects an invalid name, naming the class" do
      [nil, "", 1].each do |bad|
        expect { reactor { queue bad } }.to raise_error(RubyReactor::Error::ValidationError, /DeclReactor/)
      end
      expect { step_class { queue "" } }.to raise_error(RubyReactor::Error::ValidationError, /DeclStep/)
    end

    it "is inherited unless the subclass declares its own" do
      parent = reactor { queue :x }
      expect(Class.new(parent).declared_queue).to eq("x")

      child = Class.new(parent) { queue :z }
      expect(child.declared_queue).to eq("z")
      expect(parent.declared_queue).to eq("x")

      step_parent = step_class { queue :x }
      expect(Class.new(step_parent).declared_queue).to eq("x")
    end
  end

  describe "the static freeze" do
    it "raises on a class-level call made outside the class definition" do
      klass = reactor { queue :x }
      anonymous = Class.new(RubyReactor::Reactor) { queue :a }
      steps = step_class { queue :s }

      expect { klass.queue(:z) }.to raise_error(RubyReactor::Error::StaticConfigurationError, frozen_message)
      expect { klass.queue }.to raise_error(RubyReactor::Error::StaticConfigurationError, frozen_message)
      expect { steps.queue(:z) }.to raise_error(RubyReactor::Error::StaticConfigurationError, frozen_message)
      expect { anonymous.queue(:z) }.to raise_error(RubyReactor::Error::StaticConfigurationError, frozen_message)
      expect { reactor.queue(:z) }.to raise_error(RubyReactor::Error::StaticConfigurationError, frozen_message)

      expect([klass, anonymous, steps].map(&:declared_queue)).to eq(%w[x a s])
    end

    it "is a static configuration error, a kind of validation error" do
      expect(RubyReactor::Error::StaticConfigurationError.new.message).to eq(frozen_message)
      expect(RubyReactor::Error::StaticConfigurationError.ancestors).to include(RubyReactor::Error::ValidationError)
    end

    it "allows `self.queue` inside the body, and keeps the writer private" do
      klass = reactor { self.queue :x } # rubocop:disable Style/RedundantSelf -- explicit self is the point
      expect(klass.declared_queue).to eq("x")
      expect(klass.respond_to?(:queue)).to be(false)
      expect(step_class.respond_to?(:queue)).to be(false)
    end
  end

  describe "step blocks" do
    let(:declared_step) { step_class { queue :x } }

    it "lets a step block's declaration win over the step class's" do
      impl = declared_step
      klass = reactor do
        step(:a, impl) { queue :block }
        step :b, impl
        step(:c) { run { |_inputs, _ctx| RubyReactor.Success() } }
      end

      expect(klass.steps[:a].queue).to eq("block")
      expect(klass.steps[:b].queue).to eq("x")
      expect(klass.steps[:c].queue).to be_nil
    end

    it "does the same for async_step" do
      impl = declared_step
      klass = reactor do
        async_step(:a, impl) { queue :block }
        async_step :b, impl
      end

      expect(klass.steps[:a].queue).to eq("block")
      expect(klass.steps[:b].queue).to eq("x")
    end

    it "rejects an invalid or a second, different block declaration" do
      expect { reactor { step(:a) { queue "" } } }.to raise_error(RubyReactor::Error::ValidationError, /step :a/)
      expect { reactor { step(:a) { queue(:p) && queue(:q) } } }
        .to raise_error(RubyReactor::Error::ValidationError, /step :a/)
    end
  end

  describe "compose, map and async_reactor blocks" do
    let(:child) { reactor { step(:c) { run { |_inputs, _ctx| RubyReactor.Success() } } } }

    it "rejects `queue`, pointing at the child reactor class" do
      kid = child
      expect { reactor { compose(:x, kid) { queue :q } } }
        .to raise_error(RubyReactor::Error::ValidationError, /queue.*compose :x.*DeclReactor/)
      expect { reactor { map(:x, kid) { queue :q } } }
        .to raise_error(RubyReactor::Error::ValidationError, /queue.*map :x.*DeclReactor/)
      expect { reactor { async_reactor(:x, kid) { queue :q } } }
        .to raise_error(RubyReactor::Error::ValidationError, /queue.*async_reactor :x.*DeclReactor/)
    end
  end
end
