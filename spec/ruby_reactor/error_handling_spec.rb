# frozen_string_literal: true

RSpec.describe "Error Handling Improvements" do
  let(:reactor_class) do
    klass = Class.new(RubyReactor::Reactor) do
      input :username
      input :password, redact: true
      input :api_key, redact: true

      step :failing_step do
        run do |_args, _context|
          raise "Something went wrong"
        end
      end
    end
    stub_const("TestReactor", klass)
    klass
  end

  it "includes step name and reactor name in the error message" do
    result = reactor_class.run(username: "user", password: "secret_password", api_key: "12345")
    expect(result).to be_a(RubyReactor::Failure)
    expect(result.message).to match(/Error in reactor 'TestReactor'/)
    expect(result.message).to match(/step 'failing_step'/)

    # Check that step_name attribute is set correctly
    expect(result.step_name).to eq(:failing_step)
    expect(result.reactor_name).to eq(reactor_class.name)
  end

  it "includes inputs in the error message" do
    result = reactor_class.run(username: "user", password: "secret_password", api_key: "12345")
    expect(result).to be_a(RubyReactor::Failure)
    expect(result.message).to include("Inputs:")
    expect(result.message).to include("username: \"user\"")
  end

  it "redacts sensitive inputs" do
    result = reactor_class.run(username: "user", password: "secret_password", api_key: "12345")
    expect(result).to be_a(RubyReactor::Failure)
    expect(result.message).to include("password: [REDACTED]")
    expect(result.message).to include("api_key: [REDACTED]")
    expect(result.message).not_to include("secret_password")
    expect(result.message).not_to include("12345")
  end

  it "includes backtrace in the error message" do
    result = reactor_class.run(username: "user", password: "secret_password", api_key: "12345")
    expect(result).to be_a(RubyReactor::Failure)
    expect(result.message).to include("Backtrace:")
    # The backtrace should include the library files
    expect(result.message).to include("ruby_reactor")
  end

  context "when failure is returned explicitly" do
    let(:explicit_failure_reactor) do
      klass = Class.new(RubyReactor::Reactor) do
        input :data

        step :fail_explicitly do
          run do |_args, _context|
            RubyReactor::Failure("Explicit failure")
          end
        end
      end
      stub_const("ExplicitFailureReactor", klass)
      klass
    end

    it "includes error message and step context even if not passed explicitly" do
      # NOTE: ResultHandler now wraps all failures, so context is added even for explicit failures

      result = explicit_failure_reactor.run(data: "test")
      expect(result).to be_a(RubyReactor::Failure)
      expect(result.message).to include("Explicit failure")
      expect(result.message).to include("Error in reactor '#{explicit_failure_reactor.name}' step 'fail_explicitly'")
    end
  end
end
