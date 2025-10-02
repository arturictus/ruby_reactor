#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/ruby_reactor'

puts "=== Simple Dry-Ruby Validation Demo ==="
puts

# Example 1: Basic validation
class UserValidator < RubyReactor::Reactor
  input :name do
    required(:name).filled(:string, min_size?: 2)
  end

  input :email do
    required(:email).filled(:string)
  end

  input :age do
    required(:age).filled(:integer, gteq?: 18)
  end

  step :create_user do
    argument :name, input(:name)
    argument :email, input(:email) 
    argument :age, input(:age)
    
    run do |args, context|
      user = {
        name: args[:name],
        email: args[:email],
        age: args[:age],
        created_at: Time.now
      }
      Success(user)
    end
  end

  returns :create_user
end

puts "Testing basic validation..."

# Valid case
puts "\n✅ Valid input:"
result = UserValidator.run(
  name: "Alice Johnson",
  email: "alice@example.com", 
  age: 25
)

if result.success?
  user = result.value
  puts "  Success! User created:"
  puts "  Name: #{user[:name]}"
  puts "  Email: #{user[:email]}"
  puts "  Age: #{user[:age]}"
else
  puts "  ❌ Unexpected error: #{result.error}"
end

# Invalid case  
puts "\n❌ Invalid input:"
result = UserValidator.run(
  name: "A",           # Too short
  email: "",           # Empty
  age: 15              # Too young
)

if result.failure?
  puts "  Validation correctly failed!"
  puts "  Error: #{result.error}"
  if result.error.respond_to?(:field_errors)
    puts "  Field errors:"
    result.error.field_errors.each do |field, message|
      puts "    #{field}: #{message}"
    end
  end
else
  puts "  ❌ Should have failed!"
end

# Example 2: Optional fields
puts "\n\n--- Optional Fields Example ---"

class ProfileCreator < RubyReactor::Reactor
  input :username do
    required(:username).filled(:string, min_size?: 3)
  end

  input :bio, optional: true do
    optional(:bio).maybe(:string, max_size?: 100)
  end

  step :create_profile do
    argument :username, input(:username)
    argument :bio, input(:bio)
    
    run do |args, context|
      profile = {
        username: args[:username],
        bio: args[:bio] || "No bio provided",
        created_at: Time.now
      }
      Success(profile)
    end
  end

  returns :create_profile
end

puts "\n✅ With optional bio:"
result = ProfileCreator.run(username: "alice123", bio: "I love coding!")
if result.success?
  puts "  Profile: #{result.value}"
else
  puts "  Error: #{result.error}"
end

puts "\n✅ Without optional bio:"  
result = ProfileCreator.run(username: "bob456")
if result.success?
  puts "  Profile: #{result.value}"
else
  puts "  Error: #{result.error}"
end

puts "\n❌ Invalid username:"
result = ProfileCreator.run(username: "ab")  # Too short
if result.failure?
  puts "  Correctly failed: #{result.error}"
else
  puts "  Should have failed!"
end

puts "\n🎉 All validation examples completed!"