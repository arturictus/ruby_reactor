#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/ruby_reactor'

# Create a working validation example
puts "Testing validation with working example..."

begin
  test_class = Class.new(RubyReactor::Reactor) do
    input :name do
      required(:name).filled(:string, min_size?: 2)
    end

    input :age do 
      required(:age).filled(:integer, gteq?: 18)
    end

    step :process_user do
      argument :name, input(:name)
      argument :age, input(:age)
      
      run do |args, context|
        Success("User #{args[:name]} is #{args[:age]} years old")
      end
    end

    returns :process_user
  end

  # Test valid data
  puts "\n--- Testing valid data ---"
  result = test_class.run(name: "Alice", age: 25)
  if result.success?
    puts "✓ Success: #{result.value}"
  else
    puts "✗ Failure: #{result.error}"
    puts "  Field errors: #{result.error.field_errors}" if result.error.respond_to?(:field_errors)
  end

  # Test invalid data (short name)
  puts "\n--- Testing invalid data (short name) ---"
  result = test_class.run(name: "A", age: 25)
  if result.failure?
    puts "✓ Correctly failed: #{result.error}"
    puts "  Field errors: #{result.error.field_errors}" if result.error.respond_to?(:field_errors)
  else
    puts "✗ Should have failed but didn't: #{result.value}"
  end

  # Test invalid data (too young)
  puts "\n--- Testing invalid data (too young) ---"
  result = test_class.run(name: "Bob", age: 15)
  if result.failure?
    puts "✓ Correctly failed: #{result.error}"
    puts "  Field errors: #{result.error.field_errors}" if result.error.respond_to?(:field_errors)
  else
    puts "✗ Should have failed but didn't: #{result.value}"
  end

  # Test multiple validation errors
  puts "\n--- Testing multiple validation errors ---"
  result = test_class.run(name: "X", age: 10)
  if result.failure?
    puts "✓ Correctly failed with multiple errors: #{result.error}"
    puts "  Field errors: #{result.error.field_errors}" if result.error.respond_to?(:field_errors)
  else
    puts "✗ Should have failed but didn't: #{result.value}"
  end

rescue => e
  puts "✗ Error: #{e.message}"
  puts "  Backtrace: #{e.backtrace.first(3).join("\n  ")}"
end

puts "\nAll validation tests completed!"