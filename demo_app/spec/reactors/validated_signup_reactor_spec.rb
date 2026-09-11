require "rails_helper"

RSpec.describe ValidatedSignupReactor, type: :reactor do
  let(:valid) { { name: "Ada", email: "ada@example.com", age: 36, marketing_opt_in: true } }

  it "creates the profile, defaulting the bio the reactor never supplies" do
    reactor = test_reactor(described_class, valid)

    expect(reactor).to be_success
    expect(reactor.step_result(:profile)[:bio]).to eq("No bio provided")
  end

  it "rejects values that violate the step's contract" do
    reactor = test_reactor(described_class, valid.merge(name: "A", age: 17))

    expect(reactor).to be_failure
    expect(reactor).to have_validation_error(:name)
    expect(reactor).to have_validation_error(:age)
  end

  it "treats marketing_opt_in: false as provided" do
    reactor = test_reactor(described_class, valid.merge(marketing_opt_in: false))

    expect(reactor).to be_success
    expect(reactor.step_result(:profile)[:marketing_opt_in]).to be(false)
  end

  # A real dispatch, so the contract is enforced inside the worker and the
  # failure travels back through the notified wait to :welcome.
  describe "the async_step variant" do
    around do |example|
      original = RubyReactor.configuration.async_wait_timeout
      RubyReactor.configuration.async_wait_timeout = 5
      example.run
    ensure
      RubyReactor.configuration.async_wait_timeout = original
    end

    it "fails inside the worker with the same validation error" do
      reactor = test_reactor(ValidatedSignupAsyncReactor, valid.merge(age: 17))
      Thread.new do
        sleep 0.1
        drain_async_jobs
      end

      expect(reactor).to be_failure
      expect(reactor).to have_validation_error(:age)
    end
  end
end
