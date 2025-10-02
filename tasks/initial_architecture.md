# Ruby Reactor - Initial Architecture Boilerplate

## Overview
This document outlines the boilerplate components needed to port the Elixir Reactor library to Ruby. Reactor is a dynamic, concurrent, dependency-resolving saga orchestrator that implements the Saga pattern with compensation-based error handling and DAG-based execution planning.

## Core Concepts to Implement

### 1. Saga Pattern & Compensation
- **Purpose**: Transaction-like semantics across multiple resources without distributed transactions
- **Compensation Chain**: Each step can define how to handle failures (retry, fallback, rollback)
- **Three-level error handling**: Compensation → Undo → Global Rollback

### 2. Directed Acyclic Graph (DAG) 
- **Dependency Resolution**: Build execution graph from step arguments
- **Concurrent Execution**: Run independent steps in parallel
- **Cycle Detection**: Prevent deadlocks by validating graph structure

### 3. DSL (Domain Specific Language)
- **Reactor Definition**: Clean syntax for defining workflows
- **Step Declaration**: Define steps with arguments, dependencies, and implementations
- **Input/Output Handling**: Declare inputs and specify return values

## Required Ruby Components

### 1. Base Classes & Modules

#### `RubyReactor::Reactor`
```ruby
# Base class for all reactors
class RubyReactor::Reactor
  include RubyReactor::DSL::Reactor
  
  # Class-level configuration
  class << self
    attr_accessor :inputs, :steps, :return_step, :description
    attr_accessor :middlewares, :concurrency_settings
  end
  
  # Instance methods for execution
  def initialize(context = {})
  def run(inputs = {})
  def validate!
  def build_dependency_graph
  def plan_execution
end
```

#### `RubyReactor::Step`
```ruby
# Base class/module for step implementations
module RubyReactor::Step
  def self.included(base)
    base.extend(ClassMethods)
  end
  
  module ClassMethods
    def run(arguments, context)
      raise NotImplementedError
    end
    
    def compensate(reason, arguments, context)
      :ok # Default: accept failure and continue rollback
    end
    
    def undo(result, arguments, context)
      :ok # Default: no-op undo
    end
  end
end
```

### 2. DSL Implementation

#### `RubyReactor::DSL::Reactor`
```ruby
module RubyReactor::DSL::Reactor
  def self.included(base)
    base.extend(ClassMethods)
    base.class_eval do
      @inputs = {}
      @steps = {}
      @return_step = nil
      @middlewares = []
    end
  end
  
  module ClassMethods
    # DSL methods
    def input(name, transform: nil, description: nil)
    def step(name, impl = nil, &block)
    def return(step_name)
    def middleware(middleware_class)
    
    # Step configuration methods (used in step blocks)
    def argument(name, source, transform: nil)
    def run(&block)
    def compensate(&block)
    def undo(&block)
    def where(&predicate)
    def guard(&guard_fn)
    def wait_for(*step_names)
  end
end
```

#### `RubyReactor::DSL::StepBuilder`
```ruby
# Builder class for step configuration
class RubyReactor::DSL::StepBuilder
  attr_accessor :arguments, :run_block, :compensate_block, :undo_block
  attr_accessor :conditions, :guards, :dependencies
  
  def initialize(name, impl = nil)
  def argument(name, source, transform: nil)
  def run(&block)
  def compensate(&block)
  def undo(&block)
  def where(&predicate)
  def guard(&guard_fn)
  def wait_for(*step_names)
  def build
end
```

### 3. Argument & Template System

#### `RubyReactor::Template`
```ruby
module RubyReactor::Template
  # Base template classes for argument sources
  class Base
    def resolve(context)
      raise NotImplementedError
    end
  end
  
  class Input < Base
    def initialize(name, path = nil)
    def resolve(context)
  end
  
  class Result < Base
    def initialize(step_name, path = nil)
    def resolve(context)
  end
  
  class Value < Base
    def initialize(value)
    def resolve(context)
  end
  
  class Element < Base  # For map operations
    def initialize(map_name, path = nil)
    def resolve(context)
  end
end
```

#### Template Helper Methods
```ruby
module RubyReactor::DSL::TemplateHelpers
  def input(name, path = nil)
    RubyReactor::Template::Input.new(name, path)
  end
  
  def result(step_name, path = nil)
    RubyReactor::Template::Result.new(step_name, path)
  end
  
  def value(val)
    RubyReactor::Template::Value.new(val)
  end
  
  def element(map_name, path = nil)
    RubyReactor::Template::Element.new(map_name, path)
  end
end
```

### 4. Execution Engine

#### `RubyReactor::Executor`
```ruby
class RubyReactor::Executor
  attr_reader :reactor, :context, :dependency_graph, :intermediate_results
  attr_reader :undo_stack, :concurrency_tracker
  
  def initialize(reactor, inputs = {})
  def execute
  
  private
  
  def build_dependency_graph
  def find_ready_steps
  def execute_step(step)
  def handle_step_failure(step, error)
  def compensate_step(step, error)
  def rollback_completed_steps
  def resolve_arguments(step)
end
```

#### `RubyReactor::DependencyGraph`
```ruby
class RubyReactor::DependencyGraph
  def initialize
  def add_step(step)
  def add_dependency(from_step, to_step, relationship)
  def ready_steps
  def complete_step(step_name)
  def has_cycles?
  def topological_sort
end
```

### 5. Concurrency Management

#### `RubyReactor::ConcurrencyTracker`
```ruby
class RubyReactor::ConcurrencyTracker
  def initialize(max_concurrency = nil)
  def acquire
  def release
  def available_slots
  def wait_for_slot
end
```

#### `RubyReactor::AsyncRunner`
```ruby
class RubyReactor::AsyncRunner
  def initialize(concurrency_tracker)
  def run_async(step, &block)
  def run_sync(step, &block)
  def shutdown
end
```

### 6. Error Handling

#### `RubyReactor::Error`
```ruby
module RubyReactor::Error
  class Base < StandardError
    attr_reader :step, :context, :original_error
    
    def initialize(message, step: nil, context: nil, original_error: nil)
  end
  
  class ValidationError < Base; end
  class DependencyError < Base; end
  class CompensationError < Base; end
  class UndoError < Base; end
  class ConcurrencyError < Base; end
end
```

#### `RubyReactor::CompensationHandler`
```ruby
class RubyReactor::CompensationHandler
  def initialize(executor)
  
  def handle_failure(step, error)
    # Try compensation first
    # Fall back to undo if compensation fails
    # Return appropriate action (:retry, :continue, :halt)
  end
  
  private
  
  def compensate_step(step, error)
  def undo_completed_steps
end
```

### 7. Built-in Step Types

#### `RubyReactor::Steps::Collect`
```ruby
class RubyReactor::Steps::Collect
  include RubyReactor::Step
  
  def self.run(arguments, context)
    # Collect and optionally transform arguments
  end
end
```

#### `RubyReactor::Steps::Map`
```ruby
class RubyReactor::Steps::Map
  include RubyReactor::Step
  
  def self.run(arguments, context)
    # Execute nested steps for each item in collection
  end
end
```

#### `RubyReactor::Steps::Switch`
```ruby
class RubyReactor::Steps::Switch
  include RubyReactor::Step
  
  def self.run(arguments, context)
    # Conditional step execution based on predicates
  end
end
```

#### `RubyReactor::Steps::Compose`
```ruby
class RubyReactor::Steps::Compose
  include RubyReactor::Step
  
  def self.run(arguments, context)
    # Execute another reactor as a step
  end
end
```

### 8. Middleware System

#### `RubyReactor::Middleware::Base`
```ruby
class RubyReactor::Middleware::Base
  def call(step, arguments, context, &block)
    # Default: pass through
    yield
  end
end
```

#### `RubyReactor::Middleware::Telemetry`
```ruby
class RubyReactor::Middleware::Telemetry < Base
  def call(step, arguments, context, &block)
    # Add timing and instrumentation
  end
end
```

### 9. Context Management

#### `RubyReactor::Context`
```ruby
class RubyReactor::Context
  attr_accessor :inputs, :intermediate_results, :private_data
  attr_accessor :current_step, :retry_count, :concurrency_key
  
  def initialize(inputs = {})
  def get_input(name, path = nil)
  def get_result(step_name, path = nil)
  def set_result(step_name, value)
  def with_step(step_name, &block)
end
```

## File Structure

```
lib/
├── ruby_reactor.rb                 # Main entry point
├── ruby_reactor/
│   ├── version.rb
│   ├── reactor.rb                  # Base Reactor class
│   ├── step.rb                     # Step module
│   ├── executor.rb                 # Execution engine
│   ├── context.rb                  # Context management
│   ├── dependency_graph.rb         # DAG implementation
│   ├── concurrency_tracker.rb      # Concurrency management
│   ├── async_runner.rb            # Async execution
│   ├── compensation_handler.rb     # Error handling
│   ├── dsl/
│   │   ├── reactor.rb             # Reactor DSL
│   │   ├── step_builder.rb        # Step configuration DSL
│   │   └── template_helpers.rb    # Template helper methods
│   ├── template/
│   │   ├── base.rb
│   │   ├── input.rb
│   │   ├── result.rb
│   │   ├── value.rb
│   │   └── element.rb
│   ├── steps/
│   │   ├── collect.rb             # Built-in step types
│   │   ├── map.rb
│   │   ├── switch.rb
│   │   ├── compose.rb
│   │   ├── debug.rb
│   │   └── flunk.rb
│   ├── middleware/
│   │   ├── base.rb
│   │   └── telemetry.rb
│   └── error/
│       ├── base.rb
│       ├── validation_error.rb
│       ├── dependency_error.rb
│       ├── compensation_error.rb
│       └── undo_error.rb
```

## Implementation Phases

### Phase 1: Core Foundation
1. Basic Reactor and Step classes
2. Simple DSL implementation 
3. Template system for arguments
4. Basic execution without concurrency
5. Dependency graph construction
6. Simple error handling

### Phase 2: Advanced Features
1. Concurrency management
2. Compensation and undo mechanisms
3. Built-in step types (collect, map, switch)
4. Middleware system
5. Advanced DSL features (guards, conditions)

### Phase 3: Polish & Performance
1. Optimization for performance
2. Better error messages and debugging
3. Documentation and examples
4. Testing framework integration
5. Advanced composition features

## Example Usage Goal

```ruby
class UserRegistration < RubyReactor::Reactor
  input :email
  input :password
  
  step :validate_email do
    argument :email, input(:email)
    
    run do |args, context|
      if args[:email].include?('@')
        Success(args[:email])
      else
        Failure("Email must contain @")
      end
    end
  end
  
  step :hash_password do
    argument :password, input(:password)
    
    run do |args, context|
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
      # Remove user from database
      UserService.delete(user[:id])
      Success()
    end
  end
  
  return :create_user
end

# Usage
result = UserRegistration.run(
  email: 'alice@example.com',
  password: 'secret123'
)

case result
when Success
  puts "User created: #{result.value}"
when Failure  
  puts "Registration failed: #{result.error}"
end
```

## Dependencies to Consider

### External Gems
- **concurrent-ruby**: For thread-safe data structures and concurrency primitives
- **dry-monads**: For Result/Success/Failure pattern (optional)
- **dry-validation**: For input validation (optional)
- **zeitwerk**: For autoloading
- **logger**: For built-in logging support

### Standard Library
- **Thread**: For concurrency management
- **Fiber**: Alternative concurrency model
- **Set**: For dependency tracking
- **Digest**: For hashing and ID generation
- **JSON**: For serialization support

## Notes

- Skip asynchronous-only features in initial implementation as requested
- Focus on basic functionality first
- Ensure Ruby idioms are followed (snake_case, proper module structure)
- Consider using dry-rb ecosystem for functional programming patterns
- Plan for easy testing with RSpec integration
- Consider thread safety from the beginning
- Design for extensibility (custom step types, middleware)

This boilerplate provides a solid foundation for implementing the core Reactor functionality in Ruby while maintaining the essential patterns and capabilities of the original Elixir version.