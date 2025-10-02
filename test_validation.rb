#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/ruby_reactor'

# Simple test to verify validation integration
puts "Testing basic validation setup..."

begin
  schema = Dry::Schema.Params do
    required(:email).filled(:string)
  end
  puts "✓ Dry::Schema loaded successfully"
rescue => e
  puts "✗ Error loading Dry::Schema: #{e.message}"
  exit 1
end

begin
  validator = RubyReactor::Validation::InputValidator.new(schema)
  result = validator.call(email: "test@example.com")
  
  if result.success?
    puts "✓ InputValidator working successfully"
    puts "  Validated data: #{result.value}"
  else
    puts "✗ InputValidator failed: #{result.error}"
  end
rescue => e
  puts "✗ Error with InputValidator: #{e.message}"
  puts "  Backtrace: #{e.backtrace.first(3).join("\n  ")}"
end

begin
  puts "Available methods: #{RubyReactor::Reactor.singleton_methods.grep(/validator/)}"
  puts "Included modules: #{RubyReactor::Reactor.included_modules}"

  test_class = Class.new(RubyReactor::Reactor) do
    puts "In class definition - available methods: #{self.methods.grep(/validator/)}"
    
    input :name do
      required(:name).filled(:string, min_size?: 2)
    end

    step :process_name do
      argument :name, input(:name)
      
      run do |args, context|
        Success("Hello, #{args[:name]}!")
      end
    end

    returns :process_name
  end

  puts "✓ Reactor class with validation defined successfully"
  
  # Test with valid input
  result = test_class.run(name: "Alice")
  if result.success?
    puts "✓ Validation integration working: #{result.value}"
  else
    puts "✗ Validation integration failed: #{result.error}"
  end

  # Test with invalid input
  result = test_class.run(name: "A")  # Too short
  if result.failure?
    puts "✓ Validation correctly rejected short name: #{result.error}"
  else
    puts "✗ Validation should have failed for short name"
  end

rescue => e
  puts "✗ Error testing reactor integration: #{e.message}"
  puts "  Backtrace: #{e.backtrace.first(5).join("\n  ")}"
end

puts "Test completed!"