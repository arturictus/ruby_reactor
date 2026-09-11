# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Step input contract declaration" do
  let(:payload_schema) { Dry::Schema.Params { required(:payload).filled(:hash) } }

  def step_class(&body)
    Class.new(RubyReactor::Step) do
      def run
        Success(inputs)
      end

      class_eval(&body) if body
    end
  end

  describe "declaration forms" do
    it "records every form in declared_inputs" do
      schema = payload_schema
      user_class = stub_const("ContractUser", Class.new)
      window_block = proc { |i| i.filled(:integer, gteq?: 1) }

      klass = step_class do
        input :note
        input :name, :string, min_size?: 2
        input :user, user_class
        input :bio, :string, optional: true
        input :window, &window_block
        input :payload, validate: schema
      end

      declared = klass.declared_inputs
      expect(declared.keys).to eq(%i[note name user bio window payload])

      expect(declared[:note]).to have_attributes(type: nil, optional: false, predicates: {}, macro_block: nil,
                                                 schema: nil, validator: nil)
      expect(declared[:name]).to have_attributes(type: :string, optional: false, predicates: { min_size?: 2 })
      expect(declared[:user]).to have_attributes(type: user_class, optional: false)
      expect(declared[:bio]).to have_attributes(type: :string, optional: true)
      expect(declared[:window].macro_block).to be(window_block)
      expect(declared[:payload].schema).to be(schema)
    end

    it "lists required names in declaration order" do
      klass = step_class do
        input :b, :string
        input :opt, :string, optional: true
        input :a, :integer
      end

      expect(klass.required_input_names).to eq(%i[b a])
    end

    it "replaces an earlier declaration with the same name" do
      klass = step_class do
        input :amount, :string
        input :amount, :integer, gteq?: 1
      end

      expect(klass.declared_inputs.keys).to eq([:amount])
      expect(klass.declared_inputs[:amount].type).to eq(:integer)
    end
  end

  describe "declares_inputs?" do
    it "is false for a plain step and for the internal step classes" do
      expect(step_class.declares_inputs?).to be(false)
      expect(RubyReactor::Step::MapStep.declares_inputs?).to be(false)
      expect(RubyReactor::Step::ComposeStep.declares_inputs?).to be(false)
      expect(RubyReactor::Step::AsyncReactorStep.declares_inputs?).to be(false)
    end

    it "is true once an input is declared" do
      expect(step_class { input :x }.declares_inputs?).to be(true)
    end
  end

  describe "inheritance" do
    let(:parent) do
      step_class do
        input :amount, :integer, gteq?: 1
        input :currency, :string
      end
    end

    it "gives the child the parent's inputs plus its own" do
      child = Class.new(parent) { input :note, :string, optional: true }

      expect(child.declared_inputs.keys).to eq(%i[amount currency note])
      expect(parent.declared_inputs.keys).to eq(%i[amount currency])
    end

    it "lets a same-named child input replace the parent's without touching the parent" do
      child = Class.new(parent) { input :amount, :integer, gteq?: 100 }

      expect(child.declared_inputs[:amount].predicates).to eq(gteq?: 100)
      expect(parent.declared_inputs[:amount].predicates).to eq(gteq?: 1)
      expect { child.run({ amount: 50, currency: "USD" }, nil) }
        .to raise_error(RubyReactor::Error::InputValidationError)
      expect(parent.run({ amount: 50, currency: "USD" }, nil)).to be_success
    end

    it "applies validate_inputs from both parent and child" do
      parent_with_rule = step_class do
        input :amount, :integer
        validate_inputs { required(:amount).filled(:integer, lt?: 100) }
      end
      child = Class.new(parent_with_rule) do
        validate_inputs { required(:amount).filled(:integer, gt?: 10) }
      end

      expect(child.run({ amount: 50 }, nil)).to be_success
      expect { child.run({ amount: 5 }, nil) }.to raise_error(RubyReactor::Error::InputValidationError)
      expect { child.run({ amount: 500 }, nil) }.to raise_error(RubyReactor::Error::InputValidationError)
    end
  end

  describe "declaration-time errors" do
    it "rejects default: on a required input" do
      expect { step_class { input :x, :string, default: "y" } }
        .to raise_error(RubyReactor::Error::ValidationError, /:x.*optional: true/)
    end

    it "raises LoadError with the install message when dry-validation is missing" do
      hide_const("Dry::Schema")

      expect { step_class { input :x, :string } }.to raise_error(LoadError, /dry-validation gem is required/)
    end
  end

  describe "enforcement wrapping" do
    it "still enforces the contract when `def run` is written after the input declarations" do
      klass = Class.new(RubyReactor::Step) do
        input :amount, :integer, gteq?: 1

        def run
          Success(inputs)
        end
      end

      expect { klass.run({ amount: 0 }, nil) }.to raise_error(RubyReactor::Error::InputValidationError)
    end

    it "still enforces the parent's contract when a subclass defines its own `run`" do
      parent = step_class { input :amount, :integer, gteq?: 1 }
      child = Class.new(parent) do
        def run
          Success(:child_body_ran)
        end
      end

      expect { child.run({}, RubyReactor::Context.new) }
        .to raise_error(RubyReactor::Error::InputValidationError) { |e| expect(e.field_errors).to have_key(:amount) }
    end
  end
end
