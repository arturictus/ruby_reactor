# frozen_string_literal: true

RSpec.describe RubyReactor do
  it "has a version number" do
    expect(RubyReactor::VERSION).not_to be nil
  end

  describe "UserRegistration reactor" do
    let(:user_registration_class) do
      Class.new(RubyReactor::Reactor) do
        input :email
        input :password

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
    end

    describe "validation failures" do
      it "fails with invalid email (no @ symbol)" do
        result = user_registration_class.run(
          email: "invalid-email",
          password: "secret123"
        )

        expect(result).to be_a(RubyReactor::Failure)
        expect(result.error).to eq("Step 'validate_email' failed: Email must contain @")
      end

      it "fails with nil email" do
        result = user_registration_class.run(
          email: nil,
          password: "secret123"
        )

        expect(result).to be_a(RubyReactor::Failure)
        expect(result.error).to eq("Step 'validate_email' failed: Email must contain @")
      end

      it "fails with empty email" do
        result = user_registration_class.run(
          email: "",
          password: "secret123"
        )

        expect(result).to be_a(RubyReactor::Failure)
        expect(result.error).to eq("Step 'validate_email' failed: Email must contain @")
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
end
