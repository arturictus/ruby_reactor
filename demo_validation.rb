#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/ruby_reactor'
require 'securerandom'

puts "=== Ruby Reactor + Dry-Ruby Validation Demo ==="
puts "Demonstrating natural validation integration\n\n"

# Example 1: E-commerce Order Processing
puts "📦 Example 1: E-commerce Order Processing"
puts "=" * 50

class OrderProcessor < RubyReactor::Reactor
  input :customer do
    required(:name).filled(:string, min_size?: 2)
    required(:email).filled(:string)
    optional(:phone).maybe(:string)
  end

  input :items do
    required(:items).array(:hash) do
      required(:id).filled(:integer, gt?: 0)
      required(:quantity).filled(:integer, gt?: 0)
      required(:price).filled(:float, gt?: 0.0)
    end
  end

  input :payment do
    required(:method).filled(:string)
    required(:amount).filled(:float, gt?: 0.0)
  end

  step :validate_order do
    argument :customer, input(:customer)
    argument :items, input(:items)
    argument :payment, input(:payment)
    
    run do |args, context|
      total = args[:items].sum { |item| item[:quantity] * item[:price] }
      
      if (total - args[:payment][:amount]).abs > 0.01
        Failure("Payment amount #{args[:payment][:amount]} doesn't match order total #{total}")
      else
        Success({
          customer: args[:customer],
          items: args[:items],
          payment: args[:payment],
          total: total
        })
      end
    end
  end

  step :create_order do
    argument :validated_order, result(:validate_order)
    
    run do |args, context|
      # Simulate payment processing
      payment_result = {
        transaction_id: SecureRandom.uuid,
        status: "completed"
      }
      
      order = {
        id: SecureRandom.uuid,
        customer: args[:validated_order][:customer],
        items: args[:validated_order][:items],
        total: args[:validated_order][:total],
        payment: payment_result,
        status: "confirmed",
        created_at: Time.now
      }
      
      Success(order)
    end
  end

  returns :create_order
end

# Test with valid order
puts "\n✅ Testing valid order:"
valid_order = {
  customer: {
    name: "Alice Johnson", 
    email: "alice@example.com", 
    phone: "+1-555-0123"
  },
  items: [
    { id: 1, quantity: 2, price: 29.99 },
    { id: 2, quantity: 1, price: 15.50 }
  ],
  payment: {
    method: "credit_card",
    amount: 75.48
  }
}

result = OrderProcessor.run(valid_order)
if result.success?
  order = result.value
  puts "  Order created successfully!"
  puts "  Order ID: #{order[:id]}"
  puts "  Customer: #{order[:customer][:name]}"
  puts "  Total: $#{order[:total]}"
  puts "  Status: #{order[:status]}"
else
  puts "  ❌ Unexpected failure: #{result.error}"
end

# Test with invalid order (validation errors)
puts "\n❌ Testing invalid order (bad validation):"
invalid_order = {
  customer: {
    name: "A",  # Too short
    email: "",  # Empty
    phone: "+1-555-0123"
  },
  items: [
    { id: 0, quantity: -1, price: 29.99 },  # Invalid id and quantity
  ],
  payment: {
    method: "credit_card", 
    amount: 50.0  # Wrong amount
  }
}

result = OrderProcessor.run(invalid_order)
if result.failure?
  puts "  Validation correctly failed!"
  puts "  Error: #{result.error}"
  if result.error.respond_to?(:field_errors)
    puts "  Field errors:"
    result.error.field_errors.each do |field, message|
      puts "    - #{field}: #{message}"
    end
  end
else
  puts "  ❌ Should have failed validation!"
end

# Example 2: User Registration with Custom Schema
puts "\n\n👤 Example 2: User Registration"
puts "=" * 50

# Define reusable schemas
UserProfileSchema = Dry::Schema.Params do
  required(:username).filled(:string, min_size?: 3, max_size?: 20)
  required(:email).filled(:string)
  required(:password).filled(:string, min_size?: 8)
  optional(:age).maybe(:integer, gteq?: 13)
  optional(:bio).maybe(:string, max_size?: 500)
end

class UserRegistration < RubyReactor::Reactor
  input :profile, validate: UserProfileSchema

  step :hash_password do
    argument :profile, input(:profile)
    
    run do |args, context|
      require 'digest'
      
      hashed_profile = args[:profile].dup
      hashed_profile[:password_hash] = Digest::SHA256.hexdigest(args[:profile][:password])
      hashed_profile.delete(:password)
      
      Success(hashed_profile)
    end
  end

  step :create_user do
    argument :profile, result(:hash_password)
    
    run do |args, context|
      user = {
        id: SecureRandom.uuid,
        **args[:profile],
        created_at: Time.now,
        status: "active"
      }
      
      Success(user)
    end
  end

  returns :create_user
end

puts "\n✅ Testing valid user registration:"
valid_profile = {
  profile: {
    username: "alice_wonderland",
    email: "alice@wonderland.com", 
    password: "secret_rabbit_hole_123",
    age: 25,
    bio: "Curious adventurer who loves falling down rabbit holes."
  }
}

result = UserRegistration.run(valid_profile)
if result.success?
  user = result.value
  puts "  User registered successfully!"
  puts "  ID: #{user[:id]}"
  puts "  Username: #{user[:username]}"
  puts "  Email: #{user[:email]}"
  puts "  Age: #{user[:age] || 'Not specified'}"
  puts "  Bio: #{user[:bio] || 'No bio'}"
  puts "  Password hash: #{user[:password_hash][0..10]}..."
else
  puts "  ❌ Unexpected failure: #{result.error}"
end

puts "\n❌ Testing invalid user registration:"
invalid_profile = {
  profile: {
    username: "ab",  # Too short
    email: "",       # Empty
    password: "123", # Too short
    age: 10          # Too young
  }
}

result = UserRegistration.run(invalid_profile)
if result.failure?
  puts "  Registration correctly failed!"
  puts "  Error: #{result.error}"
else
  puts "  ❌ Should have failed validation!"
end

puts "\n\n🎉 Demo completed successfully!"
puts "The dry-ruby validation integration provides:"
puts "  ✅ Natural DSL extension"
puts "  ✅ Comprehensive validation rules"  
puts "  ✅ Clear error messages"
puts "  ✅ Backward compatibility"
puts "  ✅ Reusable validation schemas"
puts "\nReady for production use!"