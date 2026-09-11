# frozen_string_literal: true

require "spec_helper"

# US3: `inputs do ... end` inside a `step` block declares the same lines a step
# class would, and is enforced by the same InputContract#enforce!.
RSpec.describe "Inline step input contracts" do
  let(:inline_reactor) do
    Class.new(RubyReactor::Reactor) do
      input :amount
      input :currency

      step :charge do
        inputs do
          input :amount, :integer, gteq?: 1
          input :currency, :string, included_in?: %w[USD EUR]
          validate_inputs { required(:amount).filled(:integer, lt?: 10_000) }
        end

        argument :amount, input(:amount)
        argument :currency, input(:currency)
        run { |args, _| RubyReactor.Success(args) }
      end

      returns :charge
    end
  end

  let(:class_reactor) do
    stub_const("InlineEquivalentStep", Class.new(RubyReactor::Step) do
      input :amount, :integer, gteq?: 1
      input :currency, :string, included_in?: %w[USD EUR]
      validate_inputs { required(:amount).filled(:integer, lt?: 10_000) }

      def run = Success(inputs)
    end)

    Class.new(RubyReactor::Reactor) do
      input :amount
      input :currency

      step :charge, InlineEquivalentStep do
        argument :amount, input(:amount)
        argument :currency, input(:currency)
      end

      returns :charge
    end
  end

  def outcome(result)
    [result.success?, result.success? ? result.value : [result.validation_errors, result.step_name]]
  end

  it "fails with the same shape a step class produces (AS1)" do
    result = inline_reactor.run(amount: 0, currency: "USD")

    expect(result).to be_failure
    expect(result.validation_errors).to have_key(:amount)
    expect(result.step_name).to eq(:charge)
  end

  [
    { amount: 5, currency: "USD" },
    { amount: 0, currency: "USD" },
    { amount: 5, currency: "JPY" },
    { amount: 20_000, currency: "EUR" }
  ].each do |inputs|
    it "behaves identically to the class form for #{inputs} (AS2, SC-005)" do
      expect(outcome(inline_reactor.run(inputs))).to eq(outcome(class_reactor.run(inputs)))
    end
  end

  it "keeps input(:x) a template reference outside the inputs block" do
    captured = []
    Class.new(RubyReactor::Reactor) do
      input :amount

      step :charge do
        inputs { input :amount, :integer }
        captured << input(:amount)
        argument :amount, input(:amount)
        run { |args, _| RubyReactor.Success(args) }
      end
    end

    expect(captured.first).to be_a(RubyReactor::Template::Input)
  end

  it "applies defaults like a step class" do
    received = []
    reactor = Class.new(RubyReactor::Reactor) do
      input :greeting, optional: true

      step :greet do
        inputs { input :greeting, optional: true, default: "x" }
        argument :greeting, input(:greeting)
        run do |args, _|
          received << args[:greeting]
          RubyReactor.Success(args)
        end
      end
    end

    reactor.run({})
    reactor.run(greeting: false)

    expect(received).to eq(["x", false])
  end

  it "redacts like a step class" do
    stub_const("InlineTokenReactor", Class.new(RubyReactor::Reactor) do
      input :token, redact: true

      step :pay do
        inputs { input :token, :string, redact: true, min_size?: 10 }
        argument :token, input(:token)
        run { |args, _| RubyReactor.Success(args) }
      end
    end)

    result = InlineTokenReactor.run(token: "sekrit")

    expect(result.step_arguments).to eq(token: "[REDACTED]")
    expect(result.message).not_to include("sekrit")
    trace = InlineTokenReactor.find(result.execution_id).context.execution_trace
    expect(trace.find { |e| e[:type].to_s == "run" }[:arguments]).to eq(token: "[REDACTED]")
  end

  describe "conflicts" do
    before do
      stub_const("OwnedStep", Class.new(RubyReactor::Step) do
        def run = Success(inputs)
      end)
    end

    it "rejects `inputs` on a step with a class" do
      expect do
        Class.new(RubyReactor::Reactor) do
          step(:charge, OwnedStep) { inputs { input :amount } }
        end
      end.to raise_error(RubyReactor::Error::ValidationError, /`inputs` is for inline steps.*OwnedStep/)
    end

    it "rejects `inputs` plus a typed argument" do
      expect do
        Class.new(RubyReactor::Reactor) do
          input :amount
          step :charge do
            inputs { input :amount }
            argument :amount, input(:amount), :integer
            run { |args, _| RubyReactor.Success(args) }
          end
        end
      end.to raise_error(RubyReactor::Error::ValidationError, /:charge.*:amount/)
    end

    it "rejects `inputs` plus validate_args" do
      expect do
        Class.new(RubyReactor::Reactor) do
          input :amount
          step :charge do
            inputs { input :amount }
            argument :amount, input(:amount)
            validate_args { required(:amount).filled }
            run { |args, _| RubyReactor.Success(args) }
          end
        end
      end.to raise_error(RubyReactor::Error::ValidationError, /:charge/)
    end

    it "rejects an argument the inputs block does not declare" do
      expect do
        Class.new(RubyReactor::Reactor) do
          step :charge do
            inputs { input :amount }
            argument :bogus, value(1)
            run { |args, _| RubyReactor.Success(args) }
          end
        end
      end.to raise_error(RubyReactor::Error::ValidationError, /:bogus/)
    end

    it "rejects `inputs` inside an interrupt and points at validate_payload" do
      expect do
        Class.new(RubyReactor::Reactor) do
          interrupt(:approval) { inputs { input :approved } }
        end
      end.to raise_error(RubyReactor::Error::ValidationError, /interrupt :approval.*validate_payload/)
    end
  end
end
