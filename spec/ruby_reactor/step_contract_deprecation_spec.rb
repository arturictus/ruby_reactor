# frozen_string_literal: true

require "spec_helper"

# US5: rules on `argument` / `validate_args` for a step without a contract keep
# working exactly as before, and print one deprecation notice per call site.
#
# Notices are deduplicated per file:line for the whole process, so every
# example defines its reactor at its own line.
RSpec.describe "Deprecation of reactor-declared step rules" do
  def one_notice_matching(pattern)
    satisfy { |stderr| stderr.scan("[RubyReactor] DEPRECATION:").size == 1 && stderr.match?(pattern) }
  end

  it "prints a notice for a typed argument on an inline step, naming the file and line" do
    line = nil
    reactor = nil

    expect do
      reactor = Class.new(RubyReactor::Reactor) do
        input :amount

        step :charge do
          line = __LINE__ + 1
          argument :amount, input(:amount), :integer, gteq?: 1
          run { |args, _| RubyReactor.Success(args) }
        end
      end
    end.to output(
      satisfy do |stderr|
        stderr.match?(/\[RubyReactor\] DEPRECATION:.*step :charge.*argument :amount.*input :amount/) &&
          stderr.include?("#{File.basename(__FILE__)}:#{line}")
      end
    ).to_stderr

    expect(reactor.run(amount: 5)).to be_success
    expect(reactor.run(amount: 5).value[:charge]).to eq(amount: 5)
    failure = reactor.run(amount: 0)
    expect(failure.validation_errors).to have_key(:amount)
    expect(failure.step_name).to eq(:charge)
  end

  it "prints a notice for validate_args pointing at validate_inputs in an inputs block" do
    reactor = nil

    expect do
      reactor = Class.new(RubyReactor::Reactor) do
        input :amount

        step :charge do
          argument :amount, input(:amount)
          validate_args { required(:amount).filled(:integer, gteq?: 1) }
          run { |args, _| RubyReactor.Success(args) }
        end
      end
    end.to output(one_notice_matching(/validate_args.*validate_inputs.*inputs do/)).to_stderr

    expect(reactor.run(amount: 0).validation_errors).to have_key(:amount)
  end

  it "prints once for one call site defined twice" do
    expect do
      2.times do
        Class.new(RubyReactor::Reactor) do
          input :amount
          step(:charge) { argument :amount, input(:amount), :integer }
        end
      end
    end.to output(one_notice_matching(/argument :amount/)).to_stderr
  end

  it "prints for a class step with no contract, naming the class" do
    stub_const("LegacyChargeStep", Class.new do
      include RubyReactor::Step

      def self.run(args, _) = RubyReactor.Success(args)
    end)
    reactor = nil

    expect do
      reactor = Class.new(RubyReactor::Reactor) do
        input :amount
        step(:charge, LegacyChargeStep) { argument :amount, input(:amount), :integer, gteq?: 1 }
      end
    end.to output(one_notice_matching(/LegacyChargeStep/)).to_stderr

    expect(reactor.run(amount: 5)).to be_success
    failure = reactor.run(amount: 0)
    expect(failure.validation_errors).to have_key(:amount)
    expect(failure.step_name).to eq(:charge)
  end

  it "prints nothing for a mapping-only argument" do
    expect do
      Class.new(RubyReactor::Reactor) do
        input :amount
        step(:charge) { argument :amount, input(:amount) }
      end
    end.not_to output.to_stderr
  end
end
