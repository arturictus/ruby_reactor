# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('lib', __dir__))
require 'ruby_reactor'

# Create a simple reactor for user registration
class UserRegistration < RubyReactor::Reactor
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

# Test the implementation
puts "Testing RubyReactor implementation..."
puts "=" * 40

# Test successful execution
puts "\n1. Testing successful user registration:"
result = UserRegistration.run(
  email: 'alice@example.com',
  password: 'secret123'
)

case result
when RubyReactor::Success
  puts "✅ User created successfully:"
  puts result.value.inspect
when RubyReactor::Failure  
  puts "❌ Registration failed: #{result.error}"
end

# Test failure case
puts "\n2. Testing invalid email:"
result = UserRegistration.run(
  email: 'invalid-email',
  password: 'secret123'
)

case result
when RubyReactor::Success
  puts "✅ User created: #{result.value}"
when RubyReactor::Failure  
  puts "❌ Registration failed (expected): #{result.error}"
end

puts "\n=" * 40
puts "Basic implementation test completed!"