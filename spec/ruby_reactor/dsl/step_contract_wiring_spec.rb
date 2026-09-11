# frozen_string_literal: true

require "spec_helper"

# US4: a declared input with no `argument` resolves from the same-named reactor
# input; a required input satisfied by neither fails before any step runs.
RSpec.describe "Step contract wiring" do
  let(:received) { [] }

  before do
    sink = received
    stub_const("ProfileStep", Class.new(RubyReactor::Step) do
      input :name, :string
      input :email, :string
      input :bio, :string, optional: true

      define_method(:run) do
        sink << inputs
        Success(inputs)
      end
    end)
  end

  # Named before the body runs, so error messages can name the reactor.
  def define_reactor(name = "WiringReactor", &body)
    stub_const(name, Class.new(RubyReactor::Reactor))
    Object.const_get(name).class_eval(&body)
    Object.const_get(name)
  end

  describe "acceptance scenarios" do
    it "fails naming the reactor, step and missing input (AS1)" do
      reactor = define_reactor do
        input :name
        step(:profile, ProfileStep) { argument :name, input(:name) }
      end

      expect { reactor.validate_definition! }.to raise_error(
        RubyReactor::Error::ValidationError,
        /WiringReactor step :profile requires input :email.*argument :email, .*input :email/
      )
    end

    it "resolves an unwired input from the same-named reactor input (AS2)" do
      reactor = define_reactor do
        input :name
        input :email
        step :profile, ProfileStep
      end

      expect(reactor.run(name: "Ada", email: "ada@example.com")).to be_success
      expect(received).to eq([{ name: "Ada", email: "ada@example.com" }])
    end

    it "rejects wiring the step does not declare (AS3)" do
      expect do
        define_reactor do
          input :name
          input :email
          step(:profile, ProfileStep) { argument :nickname, input(:name) }
        end
      end.to raise_error(RubyReactor::Error::ValidationError, /:nickname/)
    end

    it "keeps today's implicit inputs for an inline step with no contract or arguments (AS4, FR-019)" do
      sink = received
      reactor = define_reactor do
        input :name
        input :email
        step :greet do
          run do |args, _|
            sink << args
            RubyReactor.Success(args)
          end
        end
      end

      reactor.run(name: "Ada", email: "a@b.c")

      expect(received).to eq([{ name: "Ada", email: "a@b.c" }])
    end

    it "leaves an unmatched optional input absent (AS5)" do
      reactor = define_reactor do
        input :name
        input :email
        step :profile, ProfileStep
      end

      reactor.run(name: "Ada", email: "a@b.c")

      expect(received.first).not_to have_key(:bio)
    end

    it "lets explicit wiring win over a same-named reactor input (AS6)" do
      reactor = define_reactor do
        input :name
        input :email
        step(:profile, ProfileStep) { argument :email, value("explicit@example.com") }
      end

      reactor.run(name: "Ada", email: "reactor@example.com")

      expect(received.first[:email]).to eq("explicit@example.com")
      expect(reactor.steps[:profile].arguments[:email][:origin]).to eq(:explicit)
    end
  end

  it "infers wiring for an inline step's inputs block" do
    sink = received
    reactor = define_reactor do
      input :amount
      step :charge do
        inputs { input :amount, :integer }
        run do |args, _|
          sink << args
          RubyReactor.Success(args)
        end
      end
    end

    reactor.run(amount: 3)

    expect(received).to eq([{ amount: 3 }])
    missing = define_reactor("InlineMissingReactor") { step(:charge) { inputs { input :amount } } }
    expect { missing.validate_definition! }
      .to raise_error(RubyReactor::Error::ValidationError, /step :charge requires input :amount/)
  end

  it "raises from .run and test_reactor before any step runs" do
    ran = []
    reactor = define_reactor do
      input :name
      step :first do
        run do
          ran << :first
          RubyReactor.Success(:ok)
        end
      end
      step :profile, ProfileStep
    end

    expect { reactor.run(name: "Ada") }.to raise_error(RubyReactor::Error::ValidationError, /:email/)
    expect { test_reactor(reactor, { name: "Ada" }).result }
      .to raise_error(RubyReactor::Error::ValidationError, /:email/)
    expect(ran).to be_empty
  end

  it "marks inferred entries and never consults step results" do
    reactor = define_reactor do
      input :name
      input :email
      step :profile, ProfileStep
    end
    reactor.validate_definition!

    inferred = reactor.steps[:profile].arguments[:email]
    expect(inferred[:origin]).to eq(:inferred)
    expect(inferred[:source]).to be_a(RubyReactor::Template::Input)
    expect(inferred[:source].name).to eq(:email)

    shadowed = define_reactor("ShadowReactor") do
      input :name
      step(:email) { run { RubyReactor.Success("from a step") } }
      step :profile, ProfileStep
    end
    expect { shadowed.validate_definition! }.to raise_error(RubyReactor::Error::ValidationError, /:email/)
  end

  it "is idempotent" do
    reactor = define_reactor do
      input :name
      input :email
      step :profile, ProfileStep
    end

    reactor.validate_definition!
    size = reactor.steps[:profile].arguments.size
    reactor.validate_definition!

    expect(reactor.steps[:profile].arguments.size).to eq(size)
  end

  it "still resolves by name under test_reactor(...).mock_step" do
    reactor = define_reactor do
      input :name
      input :email
      input :extra
      step :profile, ProfileStep
      returns :profile
    end

    # Without the inferred wiring the mock would receive every reactor input.
    subject = test_reactor(reactor, { name: "Ada", email: "a@b.c", extra: 1 })
              .mock_step(:profile) { |args, _ctx| RubyReactor.Success(args.merge(mocked: true)) }

    expect(subject).to be_success
    expect(subject.result.value).to eq(name: "Ada", email: "a@b.c", mocked: true)
  end
end
