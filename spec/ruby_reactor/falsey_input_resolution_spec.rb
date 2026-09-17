# frozen_string_literal: true

require "spec_helper"

# FR-023: a value is "provided" when its key exists, never when it is truthy.
# A supplied `false` must reach the step as `false`, not `nil`.
RSpec.describe "Falsey input resolution" do
  let(:received) { [] }

  def inline_reactor(sink)
    Class.new(RubyReactor::Reactor) do
      input :flag

      step :use_flag do
        argument :flag, input(:flag)
        run do |args, _ctx|
          sink << args[:flag]
          RubyReactor.Success(args[:flag])
        end
      end
    end
  end

  describe "reactor input -> inline step" do
    [false, 0, "", []].each do |value|
      it "delivers #{value.inspect} unchanged" do
        result = inline_reactor(received).run(flag: value)

        expect(result).to be_success
        expect(received).to eq([value])
      end
    end
  end

  describe "reactor input -> class step" do
    it "delivers false unchanged" do
      sink = received
      step_class = Class.new(RubyReactor::Step) do
        define_method(:run) do
          sink << inputs[:flag]
          Success(inputs[:flag])
        end
      end
      stub_const("ReceivesFlag", step_class)

      reactor = Class.new(RubyReactor::Reactor) do
        input :flag
        step :use_flag, ReceivesFlag do
          argument :flag, input(:flag)
        end
      end

      expect(reactor.run(flag: false)).to be_success
      expect(received).to eq([false])
    end
  end

  describe "prior step result -> next step" do
    it "delivers a false result unchanged" do
      sink = received
      reactor = Class.new(RubyReactor::Reactor) do
        step :first do
          run { RubyReactor.Success(false) }
        end

        step :second do
          argument :flag, result(:first)
          run do |args, _ctx|
            sink << args[:flag]
            RubyReactor.Success(args[:flag])
          end
        end
      end

      expect(reactor.run({})).to be_success
      expect(received).to eq([false])
    end
  end

  describe "nested paths" do
    it "keeps a false leaf through input(:name, :key), input(:name, [..]) and result(:step, :key)" do
      sink = received
      reactor = Class.new(RubyReactor::Reactor) do
        input :config

        step :first do
          run { RubyReactor.Success({ flag: false }) }
        end

        step :read do
          argument :notify, input(:config, :notify)
          argument :deep, input(:config, %i[a notify])
          argument :flag, result(:first, :flag)
          run do |args, _ctx|
            sink << args
            RubyReactor.Success(args)
          end
        end
      end

      expect(reactor.run(config: { notify: false, a: { notify: false } })).to be_success
      expect(received).to eq([{ notify: false, deep: false, flag: false }])
    end
  end

  describe RubyReactor::Context do
    it "returns false from get_input for symbol and string keys" do
      expect(described_class.new({ flag: false }).get_input(:flag)).to be(false)
      expect(described_class.new({ "flag" => false }).get_input(:flag)).to be(false)
    end

    it "returns false from get_result for symbol and string keys" do
      ctx = described_class.new({})
      ctx.intermediate_results[:done] = false
      ctx.intermediate_results["other"] = false

      expect(ctx.get_result(:done)).to be(false)
      expect(ctx.get_result(:other)).to be(false)
    end

    it "keeps false through a serialization round trip" do
      stub_const("FalseyRoundTripReactor", Class.new(RubyReactor::Reactor))
      ctx = described_class.new({ flag: false }, FalseyRoundTripReactor)
      restored = RubyReactor::ContextSerializer.deserialize(RubyReactor::ContextSerializer.serialize(ctx))

      expect(restored.get_input(:flag)).to be(false)
    end
  end

  describe RubyReactor::Template::Result do
    it "fetches false for symbol and string keys" do
      template = described_class.new(:any)

      expect(template.send(:fetch, { success: false }, :success)).to be(false)
      expect(template.send(:fetch, { "success" => false }, :success)).to be(false)
    end
  end
end
