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
          
          run do |args, context|
            if args[:email] && args[:email].include?('@')
              Success(args[:email])
            else
              Failure("Email must contain @")
            end
          end
        end

        step :hash_password do
          argument :password, input(:password)
          
          run do |args, context|
            require 'digest'
            hashed = Digest::SHA256.hexdigest(args[:password])
            Success(hashed)
          end
        end

        step :create_user do
          argument :email, result(:validate_email)
          argument :password_hash, result(:hash_password)
          
          run do |args, context|
            user = {
              id: rand(10000),
              email: args[:email],
              password_hash: args[:password_hash],
              created_at: Time.now
            }
            Success(user)
          end
          
          undo do |user, args, context|
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
          email: 'alice@example.com',
          password: 'secret123'
        )

        expect(result).to be_a(RubyReactor::Success)
        user = result.value
        expect(user).to be_a(Hash)
        expect(user[:email]).to eq('alice@example.com')
        expect(user[:password_hash]).to be_a(String)
        expect(user[:password_hash]).not_to eq('secret123') # Should be hashed
        expect(user[:id]).to be_a(Integer)
        expect(user[:created_at]).to be_a(Time)
      end

      it "hashes the password correctly" do
        result = user_registration_class.run(
          email: 'test@example.com',
          password: 'testpassword'
        )

        expect(result).to be_a(RubyReactor::Success)
        
        user = result.value
        expected_hash = Digest::SHA256.hexdigest('testpassword')
        expect(user[:password_hash]).to eq(expected_hash)
      end
    end

    describe "validation failures" do
      it "fails with invalid email (no @ symbol)" do
        result = user_registration_class.run(
          email: 'invalid-email',
          password: 'secret123'
        )

        expect(result).to be_a(RubyReactor::Failure)
        expect(result.error).to eq("Step 'validate_email' failed: Email must contain @")
      end

      it "fails with nil email" do
        result = user_registration_class.run(
          email: nil,
          password: 'secret123'
        )

        expect(result).to be_a(RubyReactor::Failure)
        expect(result.error).to eq("Step 'validate_email' failed: Email must contain @")
      end

      it "fails with empty email" do
        result = user_registration_class.run(
          email: '',
          password: 'secret123'
        )

        expect(result).to be_a(RubyReactor::Failure)
        expect(result.error).to eq("Step 'validate_email' failed: Email must contain @")
      end
    end

    describe "step validation" do
      it "validates email step correctly" do
        valid_emails = [
          'user@example.com',
          'test.email@domain.org',
          'name+tag@site.co.uk'
        ]

        valid_emails.each do |email|
          result = user_registration_class.run(
            email: email,
            password: 'password'
          )
          expect(result).to be_a(RubyReactor::Success), 
                 "Expected #{email} to be valid"
        end
      end

      it "rejects invalid emails" do
        invalid_emails = [
          'plainaddress',
          'missing-at-sign.com',
          'no-at-symbol.com'
        ]

        invalid_emails.each do |email|
          result = user_registration_class.run(
            email: email,
            password: 'password'
          )
          expect(result).to be_a(RubyReactor::Failure), 
                 "Expected #{email} to be invalid"
        end
      end
    end
  end
end
