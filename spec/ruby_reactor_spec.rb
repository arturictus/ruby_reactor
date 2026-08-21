# frozen_string_literal: true

RSpec.describe RubyReactor do
  it "has a version number" do
    expect(RubyReactor::VERSION).not_to be_nil
  end

  describe "UserRegistration reactor" do
    let(:user_registration_class) do
      Class.new(RubyReactor::Reactor) do
        input :email
        input :password

        retry_defaults max_attempts: 3

        step :validate_email do
          argument :email, input(:email)

          run do |args, _context|
            if args[:email]&.include?("@")
              Success(args[:email])
            else
              Failure("Email must contain @")
            end
          end
        end

        step :hash_password do
          argument :password, input(:password)

          run do |args, _context|
            require "digest"
            hashed = Digest::SHA256.hexdigest(args[:password])
            Success(hashed)
          end
        end

        step :create_user do
          argument :email, result(:validate_email)
          argument :password_hash, result(:hash_password)

          run do |args, _context|
            user = {
              id: rand(10_000),
              email: args[:email],
              password_hash: args[:password_hash],
              created_at: Time.now
            }
            Success(user)
          end

          undo do |user, _args, _context|
            puts "Would delete user with ID: #{user[:id]}"
            Success()
          end
        end

        returns :create_user
      end
    end

    describe "successful user registration" do
      it "creates a user with valid email and password" do
        result = user_registration_class.run(
          email: "alice@example.com",
          password: "secret123"
        )

        expect(result).to be_a(RubyReactor::Success)
        user = result.value
        expect(user).to be_a(Hash)
        expect(user[:email]).to eq("alice@example.com")
        expect(user[:password_hash]).to be_a(String)
        expect(user[:password_hash]).not_to eq("secret123") # Should be hashed
        expect(user[:id]).to be_a(Integer)
        expect(user[:created_at]).to be_a(Time)
      end

      it "hashes the password correctly" do
        result = user_registration_class.run(
          email: "test@example.com",
          password: "testpassword"
        )

        expect(result).to be_a(RubyReactor::Success)

        user = result.value
        expected_hash = Digest::SHA256.hexdigest("testpassword")
        expect(user[:password_hash]).to eq(expected_hash)
      end

      it "tracks execution order in execution_trace" do
        reactor = user_registration_class.new
        result = reactor.run(
          email: "trace@example.com",
          password: "tracepass"
        )

        expect(result).to be_a(RubyReactor::Success)
        expect(reactor.execution_trace).to be_an(Array)
        expect(reactor.execution_trace.length).to eq(3) # validate_email, hash_password, create_user

        # Check the steps are in order
        run_steps = reactor.execution_trace.select { |entry| entry[:type] == :run }.map { |entry| entry[:step] }
        expect(run_steps).to eq(%i[validate_email hash_password create_user])

        # Check each run entry has timestamp and arguments
        reactor.execution_trace.each do |entry|
          expect(entry).to have_key(:timestamp)
          expect(entry).to have_key(:type)
          expect(entry).to have_key(:step)
          expect(entry[:timestamp]).to be_a(Time)
          case entry[:type]
          when :run
            expect(entry).to have_key(:arguments)
          when :undo
            expect(entry).to have_key(:result)
            expect(entry).to have_key(:arguments)
          when :compensate
            expect(entry).to have_key(:error)
            expect(entry).to have_key(:arguments)
          end
        end
      end
    end

    describe "validation failures" do
      it "fails with invalid email (no @ symbol)" do
        result = user_registration_class.run(
          email: "invalid-email",
          password: "secret123"
        )

        expect(result).to be_a(RubyReactor::Failure)
        expect(result.error).to eq("Step 'validate_email' failed after 3 attempts: Email must contain @")
      end

      it "fails with nil email" do
        result = user_registration_class.run(
          email: nil,
          password: "secret123"
        )

        expect(result).to be_a(RubyReactor::Failure)
        expect(result.error).to eq("Step 'validate_email' failed after 3 attempts: Email must contain @")
      end

      it "fails with empty email" do
        result = user_registration_class.run(
          email: "",
          password: "secret123"
        )

        expect(result).to be_a(RubyReactor::Failure)
        expect(result.error).to eq("Step 'validate_email' failed after 3 attempts: Email must contain @")
      end
    end

    describe "step validation" do
      it "validates email step correctly" do
        valid_emails = [
          "user@example.com",
          "test.email@domain.org",
          "name+tag@site.co.uk"
        ]

        valid_emails.each do |email|
          result = user_registration_class.run(
            email: email,
            password: "password"
          )
          expect(result).to be_a(RubyReactor::Success),
                            "Expected #{email} to be valid"
        end
      end

      it "rejects invalid emails" do
        invalid_emails = [
          "plainaddress",
          "missing-at-sign.com",
          "no-at-symbol.com"
        ]

        invalid_emails.each do |email|
          result = user_registration_class.run(
            email: email,
            password: "password"
          )
          expect(result).to be_a(RubyReactor::Failure),
                            "Expected #{email} to be invalid"
        end
      end
    end
  end

  describe "doesn't retry with default max attempts of 1" do
    let(:flaky_step_class) do
      Class.new(RubyReactor::Reactor) do
        step :flaky_step do
          run do |_args, context|
            puts "running flaky_step"
            attempt = context.retry_context.attempts_for_step(:flaky_step)
            Failure("Intentional failure on attempt #{attempt}")
          end
        end
      end
    end

    it "never retries" do
      executor = flaky_step_class.new
      result = executor.run

      expect(result).to be_a(RubyReactor::Failure)
      expect(result.error).to eq("Step 'flaky_step' failed after 1 attempts: Intentional failure on attempt 1")
    end
  end

  describe "Max attempts behavior" do
    let(:flaky_step_class) do
      Class.new(RubyReactor::Reactor) do
        retry_defaults max_attempts: 3
        input :should_fail_times do
          required(:should_fail_times).filled(:integer, gteq?: 0)
        end

        step :flaky_step do
          argument :should_fail_times, input(:should_fail_times)

          run do |args, context|
            attempt = context.retry_context.attempts_for_step(:flaky_step)
            if attempt < args[:should_fail_times]
              Failure("Intentional failure on attempt #{attempt}")
            else
              Success("Succeeded on attempt #{attempt}")
            end
          end
        end

        returns :flaky_step
      end
    end

    it "retries until max attempts are reached returning failure" do
      reactor = flaky_step_class.new
      result = reactor.run(should_fail_times: 4)
      expect(result).to be_a(RubyReactor::Failure)
      expect(result.error).to eq("Step 'flaky_step' failed after 3 attempts: Intentional failure on attempt 3")
    end

    it "retries until max attempts are reached returning success" do
      reactor = flaky_step_class.new
      result = reactor.run(should_fail_times: 2)
      expect(result).to be_a(RubyReactor::Success)
      expect(result.value).to eq("Succeeded on attempt 2")
    end
  end

  describe "wait_for" do
    let(:wait_for_reactor_class) do
      Class.new(RubyReactor::Reactor) do
        step :step_one do
          run do |_args, _context|
            Success("Result from step one")
          end
        end

        step :step_two do
          wait_for :step_one

          run do |_args, context|
            Success("Result from step two using #{context.get_result(:step_one)}")
          end
        end

        step :step_after_two do
          wait_for :step_two

          run do |_args, context|
            Success("Result from step after two using #{context.get_result(:step_two)}")
          end
        end

        step :step_four do
          wait_for :step_two, :step_after_two

          run do |_args, context|
            Success("Result from step four using #{context.get_result(:step_two)} /
                     and #{context.get_result(:step_after_two)}")
          end
        end

        returns :step_two
      end
    end

    it "executes dependent steps in order" do
      reactor = wait_for_reactor_class.new
      result = reactor.run
      expect(reactor.context.execution_trace.select { |e| e[:type] == :run }.map { |e| e[:step] }).to eq(
        %i[step_one step_two step_after_two step_four]
      )
      expect(result).to be_a(RubyReactor::Success)
      expect(result.value).to eq("Result from step two using Result from step one")
    end
  end

  describe "Dry-Ruby Validation Integration" do
    describe "input validation with dry-schema" do
      let(:validated_user_class) do
        Class.new(RubyReactor::Reactor) do
          input :name do
            required(:name).filled(:string, min_size?: 2)
          end

          input :email do
            required(:email).filled(:string)
          end

          input :age do
            required(:age).filled(:integer, gteq?: 18)
          end

          step :create_profile do
            argument :name, input(:name)
            argument :email, input(:email)
            argument :age, input(:age)

            run do |args, _context|
              profile = {
                name: args[:name],
                email: args[:email],
                age: args[:age],
                created_at: Time.now
              }
              Success(profile)
            end
          end

          returns :create_profile
        end
      end

      context "with valid inputs" do
        it "successfully processes valid data" do
          result = validated_user_class.run(
            name: "Alice Johnson",
            email: "alice@example.com",
            age: 25
          )

          expect(result).to be_a(RubyReactor::Success)
          profile = result.value
          expect(profile[:name]).to eq("Alice Johnson")
          expect(profile[:email]).to eq("alice@example.com")
          expect(profile[:age]).to eq(25)
          expect(profile[:created_at]).to be_a(Time)
        end
      end

      context "with invalid inputs" do
        it "fails with short name" do
          result = validated_user_class.run(
            name: "A",  # Too short
            email: "alice@example.com",
            age: 25
          )

          expect(result).to be_a(RubyReactor::Failure)
          expect(result.error).to be_a(RubyReactor::Error::InputValidationError)
          expect(result.error.field_errors).to have_key(:name)
          expect(result.error.field_errors[:name]).to include("size cannot be less than 2")
        end

        it "fails with empty email" do
          result = validated_user_class.run(
            name: "Alice",
            email: "",  # Empty
            age: 25
          )

          expect(result).to be_a(RubyReactor::Failure)
          expect(result.error).to be_a(RubyReactor::Error::InputValidationError)
          expect(result.error.field_errors).to have_key(:email)
          expect(result.error.field_errors[:email]).to include("must be filled")
        end

        it "fails with underage user" do
          result = validated_user_class.run(
            name: "Bob",
            email: "bob@example.com",
            age: 15 # Too young
          )

          expect(result).to be_a(RubyReactor::Failure)
          expect(result.error).to be_a(RubyReactor::Error::InputValidationError)
          expect(result.error.field_errors).to have_key(:age)
          expect(result.error.field_errors[:age]).to include("must be greater than or equal to 18")
        end

        it "accumulates multiple validation errors" do
          result = validated_user_class.run(
            name: "A",   # Too short
            email: "",   # Empty
            age: 10      # Too young
          )

          expect(result).to be_a(RubyReactor::Failure)
          expect(result.error).to be_a(RubyReactor::Error::InputValidationError)
          expect(result.error.field_errors.keys).to include(:name, :email, :age)

          # Check that the error message contains information about all failed fields
          error_message = result.error.message
          expect(error_message).to include("name")
          expect(error_message).to include("email")
          expect(error_message).to include("age")
        end
      end
    end

    describe "optional input validation" do
      let(:profile_class) do
        Class.new(RubyReactor::Reactor) do
          input :username do
            required(:username).filled(:string, min_size?: 3)
          end

          input :bio, optional: true do
            optional(:bio).maybe(:string, max_size?: 100)
          end

          step :create_profile do
            argument :username, input(:username)
            argument :bio, input(:bio)

            run do |args, _context|
              profile = {
                username: args[:username],
                bio: args[:bio] || "No bio provided"
              }
              Success(profile)
            end
          end

          returns :create_profile
        end
      end

      it "works with optional field provided" do
        result = profile_class.run(
          username: "alice123",
          bio: "I love coding!"
        )

        expect(result).to be_a(RubyReactor::Success)
        expect(result.value[:username]).to eq("alice123")
        expect(result.value[:bio]).to eq("I love coding!")
      end

      it "works without optional field" do
        result = profile_class.run(username: "bob456")

        expect(result).to be_a(RubyReactor::Success)
        expect(result.value[:username]).to eq("bob456")
        expect(result.value[:bio]).to eq("No bio provided")
      end

      it "validates optional field when provided" do
        result = profile_class.run(
          username: "alice123",
          bio: "x" * 150 # Too long
        )

        expect(result).to be_a(RubyReactor::Failure)
        expect(result.error).to be_a(RubyReactor::Error::InputValidationError)
        expect(result.error.field_errors).to have_key(:bio)
      end

      it "fails on required field validation" do
        result = profile_class.run(username: "ab") # Too short

        expect(result).to be_a(RubyReactor::Failure)
        expect(result.error).to be_a(RubyReactor::Error::InputValidationError)
        expect(result.error.field_errors).to have_key(:username)
        expect(result.error.field_errors[:username]).to include("size cannot be less than 3")
      end
    end

    describe "pre-defined schema validation" do
      let(:user_schema) do
        Dry::Schema.Params do
          required(:user).hash do
            required(:name).filled(:string, min_size?: 2)
            required(:email).filled(:string)
            optional(:phone).maybe(:string)
          end
        end
      end

      let(:schema_reactor_class) do
        schema = user_schema
        Class.new(RubyReactor::Reactor) do
          input :user, validate: schema

          step :create_user do
            argument :user, input(:user)

            run do |args, _context|
              Success(args[:user])
            end
          end

          returns :create_user
        end
      end

      it "validates using pre-defined schema" do
        result = schema_reactor_class.run(
          user: {
            name: "Alice",
            email: "alice@example.com",
            phone: "+1-555-0123"
          }
        )

        expect(result).to be_a(RubyReactor::Success)
        expect(result.value[:name]).to eq("Alice")
        expect(result.value[:email]).to eq("alice@example.com")
        expect(result.value[:phone]).to eq("+1-555-0123")
      end

      it "fails validation with pre-defined schema" do
        result = schema_reactor_class.run(
          user: {
            name: "A",  # Too short
            email: ""   # Empty
          }
        )

        expect(result).to be_a(RubyReactor::Failure)
        expect(result.error).to be_a(RubyReactor::Error::InputValidationError)
        expect(result.error.field_errors.keys.map(&:to_s)).to include("user[name]", "user[email]")
      end
    end

    describe "backward compatibility" do
      it "works without validation (existing behavior)" do
        no_validation_class = Class.new(RubyReactor::Reactor) do
          input :data

          step :process do
            argument :data, input(:data)

            run do |args, _context|
              Success(args[:data])
            end
          end

          returns :process
        end

        result = no_validation_class.run(data: "anything")

        expect(result).to be_a(RubyReactor::Success)
        expect(result.value).to eq("anything")
      end
    end

    describe "validation error structure" do
      let(:error_test_class) do
        Class.new(RubyReactor::Reactor) do
          input :test_field do
            required(:test_field).filled(:string, min_size?: 5)
          end

          step :process do
            argument :test_field, input(:test_field)
            run { |args, _context| Success(args) }
          end

          returns :process
        end
      end

      it "provides structured error information" do
        result = error_test_class.run(test_field: "abc")

        expect(result).to be_a(RubyReactor::Failure)

        error = result.error
        expect(error).to be_a(RubyReactor::Error::InputValidationError)
        expect(error.field_errors).to be_a(Hash)
        expect(error.field_errors).to have_key(:test_field)
        expect(error.message).to be_a(String)
        expect(error.message).to include("Input validation failed")
        expect(error.to_s).to eq(error.message)
      end
    end
  end

  describe "compose feature" do
    let(:inner_reactor_class) do
      Class.new(RubyReactor::Reactor) do
        input :value

        step :double_value do
          argument :value, input(:value)

          run do |args, _context|
            Success(args[:value] * 2)
          end
        end

        returns :double_value
      end
    end

    let(:outer_reactor_class) do
      inner_class = inner_reactor_class
      Class.new(RubyReactor::Reactor) do
        input :number

        compose :process_number, inner_class do
          argument :value, input(:number)
        end

        returns :process_number
      end
    end

    it "executes composed reactors successfully" do
      result = outer_reactor_class.run(number: 5)

      expect(result).to be_a(RubyReactor::Success)
      expect(result.value).to eq(10)
    end

    it "handles composed reactor failures" do
      # Create an inner reactor that fails
      failing_inner_class = Class.new(RubyReactor::Reactor) do
        input :value

        step :fail_step do
          run do |_args, _context|
            Failure("Intentional failure")
          end
        end

        returns :fail_step
      end

      failing_outer_class = Class.new(RubyReactor::Reactor) do
        input :number

        compose :failing_process, failing_inner_class do
          argument :value, input(:number)
        end

        returns :failing_process
      end

      result = failing_outer_class.run(number: 5)

      expect(result).to be_a(RubyReactor::Failure)
      expect(result.error).to include("Intentional failure")
    end

    # Define named classes for async testing
    class TestInnerReactorWithAsync < RubyReactor::Reactor
      input :value

      step :sync_step do
        run do |args, _context|
          puts "[INNER] Executing sync_step with value: #{args[:value]}"
          RubyReactor.Success(args[:value] * 2)
        end
      end

      step :async_step do
        argument :doubled, result(:sync_step)

        run do |args, _context|
          puts "[INNER] Executing async_step with doubled: #{args[:doubled]}"
          RubyReactor.Success(args[:doubled] + 1)
        end
      end

      background before: :async_step

      returns :async_step
    end

    class TestOuterReactorWithAsyncCompose < RubyReactor::Reactor
      input :number

      step :validate_number do
        run do |args, _context|
          if args[:number].is_a?(Numeric) && args[:number] >= 0
            RubyReactor.Success(args[:number])
          else
            RubyReactor.Failure("Number must be a non-negative numeric value")
          end
        end
      end

      compose :async_process, TestInnerReactorWithAsync do
        argument :value, result(:validate_number)
      end

      background before: :async_process

      step :after_compose do
        argument :result, result(:async_process)

        run do |args, _context|
          RubyReactor.Success(args[:result] * 2)
        end
      end

      returns :after_compose
    end

    it "executes async composed reactors in a single worker with internal async steps" do
      # The compose step is where this reactor hands off to a worker.
      expect(TestOuterReactorWithAsyncCompose.background_handoff)
        .to eq({ mode: :before, step: :async_process })

      # Run the reactor with inline Sidekiq
      result = Sidekiq::Testing.inline! do
        TestOuterReactorWithAsyncCompose.run(number: 5)
      end

      # In test mode, the worker executes inline and returns the actual result
      expect(result.success?).to be true
      expect(result.value).to eq(22) # 5 * 2 = 10, then 10 + 1 = 11, then 11 * 2 = 22
    end

    # Define named classes for retry testing
    class TestRetryInnerReactor < RubyReactor::Reactor
      input :value

      step :failing_step do
        retries max_attempts: 10, backoff: :fixed, base_delay: 1

        run do |args, context|
          attempt = context.retry_context.attempts_for_step(:failing_step)
          puts "[INNER RETRY] Attempt #{attempt} for value: #{args[:value]}"
          if attempt < 5 # First 4 attempts fail, fifth succeeds
            RubyReactor.Failure("Temporary failure")
          else
            RubyReactor.Success(args[:value] * 3)
          end
        end
      end

      returns :failing_step
    end

    class TestRetryOuterReactor < RubyReactor::Reactor
      input :number

      compose :retry_process, TestRetryInnerReactor do
        # retries max_attempts: 2, backoff: :fixed, base_delay: 1
        argument :value, input(:number)
      end

      background before: :retry_process

      step :after_compose do
        argument :result, result(:retry_process)
        argument :input, input(:number)

        run do |args, _context|
          puts "[OUTER RETRY] after_compose with result: #{args[:result]}"
          RubyReactor.Success(args[:result] + args[:input])
        end
      end

      returns :after_compose
    end

    it "retries async composed reactors by queuing new jobs" do
      expect(TestRetryOuterReactor.background_handoff).to eq({ mode: :before, step: :retry_process })

      # Run the reactor with inline Sidekiq
      result = Sidekiq::Testing.inline! do
        TestRetryOuterReactor.run(number: 5)
      end

      # In test mode, the worker executes inline and returns the actual result
      expect(result.success?).to be true
      expect(result.value).to eq(20) # 5 * 3 = 15 after retry, then + 5 in after_compose
    end
  end

  describe "AsyncResult returns job_id and intermediate_results" do
    let(:reactor_class) do
      Class.new(RubyReactor::Reactor) do
        input :value

        step :sync_step do
          run do |args, _context|
            Success(args[:value] + 1)
          end
        end
        step :async_step do
          argument :value, result(:sync_step)
          run do |args, _context|
            Success(args[:value] * 2)
          end
        end

        background before: :async_step
      end
    end

    before do
      allow(RubyReactor::Configuration.instance).to receive(:async_router).and_return(RubyReactor::Adapters::Sidekiq::Router)
    end

    it "returns job_id and intermediate_results correctly" do
      reactor = reactor_class.new
      async_result = reactor.run(value: 10)

      expect(async_result).to be_a(RubyReactor::AsyncResult)
      expect(async_result.job_id).not_to be_nil
      expect(async_result.intermediate_results).to be_a(Hash)
      expect(async_result.intermediate_results).to have_key(:sync_step)
      expect(async_result.intermediate_results[:sync_step]).to eq(11) # 10 + 1
    end
  end
end
