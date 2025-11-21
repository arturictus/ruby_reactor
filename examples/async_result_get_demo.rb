#!/usr/bin/env ruby
# frozen_string_literal: true

# Demo script showing AsyncResult#get functionality

require_relative "../lib/ruby_reactor"
require "sidekiq/testing"

# Mock sidekiq for demo purposes
Sidekiq::Testing.fake!

# Example reactor with async step
class UserRegistrationReactor < RubyReactor::Reactor
  input :email
  input :password

  step :validate_email do
    argument :email, input(:email)

    run do |args, _context|
      puts "✓ Validating email: #{args[:email]}"
      RubyReactor::Success(args[:email].downcase)
    end
  end

  step :hash_password do
    argument :password, input(:password)

    run do |args, _context|
      puts "✓ Hashing password..."
      RubyReactor::Success("hashed_#{args[:password]}")
    end
  end

  step :create_user do
    async true  # This step will be executed asynchronously
    argument :email, result(:validate_email)
    argument :password_hash, result(:hash_password)

    run do |args, _context|
      puts "✓ Creating user (async)..."
      user = { id: 999, email: args[:email], password_hash: args[:password_hash] }
      RubyReactor::Success(user)
    end
  end

  returns :create_user
end

puts "=" * 60
puts "AsyncResult#get Demo"
puts "=" * 60
puts

puts "Running reactor with async step..."
puts

reactor = UserRegistrationReactor.new
result = reactor.run(email: "Alice@Example.com", password: "secret123")

puts
puts "Reactor returned: #{result.class}"
puts

if result.is_a?(RubyReactor::AsyncResult)
  puts "AsyncResult received! Job ID: #{result.job_id}"
  puts
  puts "Steps executed before async handoff:"
  puts

  # Get results from steps that were executed
  validated_email = result.get(:validate_email)
  hashed_password = result.get(:hash_password)
  user = result.get(:create_user)

  puts "  validate_email: #{validated_email.inspect}"
  puts "  hash_password:  #{hashed_password.inspect}"
  puts "  create_user:    #{user.inspect} (nil - not executed yet)"
  puts
  puts "✓ You can retrieve results of already executed steps!"
else
  puts "Unexpected result type: #{result}"
end

puts
puts "=" * 60
