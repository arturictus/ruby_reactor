# frozen_string_literal: true

require "spec_helper"

# FR-001/FR-002/FR-004: one `retries` vocabulary, defaults and validation for
# step classes and every reactor step block.
RSpec.describe "Step retries: declaring `retries`" do
  {
    "a step class" => lambda { |&decl|
      Class.new(RubyReactor::Step) { instance_eval(&decl) }.retry_config
    },
    "an inline step block" => lambda { |&decl|
      reactor_class = Class.new(RubyReactor::Reactor) do
        step(:s) do
          instance_eval(&decl)
          run { |_args, _ctx| RubyReactor.Success() }
        end
      end
      reactor_class.steps[:s].retry_config
    }
  }.each do |owner, declare|
    context "when declared on #{owner}" do
      it "defaults to 3 exponential attempts with a 1s base delay" do
        expect(declare.call { retries }).to eq(max_attempts: 3, backoff: :exponential, base_delay: 1)
      end

      it "keeps the other defaults when only max_attempts is given" do
        expect(declare.call { retries max_attempts: 5 })
          .to eq(max_attempts: 5, backoff: :exponential, base_delay: 1)
      end

      [0, -1, 2.5, "3"].each do |bad|
        it "rejects max_attempts: #{bad.inspect}" do
          expect { declare.call { retries max_attempts: bad } }
            .to raise_error(ArgumentError, /max_attempts.*#{Regexp.escape(bad.inspect)}/)
        end
      end

      it "rejects an unknown backoff strategy" do
        expect { declare.call { retries backoff: :bogus } }.to raise_error(ArgumentError, /backoff.*:bogus/)
      end

      it "rejects a negative base_delay" do
        expect { declare.call { retries base_delay: -1 } }.to raise_error(ArgumentError, /base_delay.*-1/)
      end

      it "accepts a zero or fractional base_delay" do
        expect(declare.call { retries base_delay: 0 }[:base_delay]).to eq(0)
        expect(declare.call { retries base_delay: 0.5 }[:base_delay]).to eq(0.5)
      end
    end
  end

  it "names the step class in a validation error" do
    stub_const("DeclarationSpecChargeStep", Class.new(RubyReactor::Step))

    expect { DeclarationSpecChargeStep.class_eval { retries max_attempts: 0 } }
      .to raise_error(ArgumentError, /DeclarationSpecChargeStep: retries max_attempts/)
  end

  it "names the step in an inline validation error" do
    expect do
      Class.new(RubyReactor::Reactor) do
        step(:charge) { retries max_attempts: 0 }
      end
    end.to raise_error(ArgumentError, /charge: retries max_attempts/)
  end

  it "validates `retries` in a compose block" do
    child = Class.new(RubyReactor::Reactor) { step(:inner) { run { |_a, _c| RubyReactor.Success() } } }

    expect do
      Class.new(RubyReactor::Reactor) { compose(:c, child) { retries backoff: :bogus } }
    end.to raise_error(ArgumentError, /backoff/)
  end

  it "validates `retries` in an async_reactor block" do
    child = Class.new(RubyReactor::Reactor) { step(:inner) { run { |_a, _c| RubyReactor.Success() } } }

    expect do
      Class.new(RubyReactor::Reactor) { async_reactor(:a, child) { retries backoff: :bogus } }
    end.to raise_error(ArgumentError, /backoff/)
  end
end
