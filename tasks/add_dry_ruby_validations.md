# Adding Dry-Ruby Validations to Ruby Reactor

## Overview

This proposal outlines how to integrate dry-ruby validations into Ruby Reactor in a way that feels natural with the existing DSL. The approach focuses on extending the current `input` declaration and adding validation support to steps, while maintaining backward compatibility.

## Current DSL Analysis

The Ruby Reactor currently has a clean DSL:

```ruby
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
end
```

## Proposed Integration Strategy

### 1. Enhanced Input Declarations with Validations

Extend the `input` method to support dry-schema validations:

```ruby
class UserRegistration < RubyReactor::Reactor
  input :email do
    required(:email).filled(:string).format?(/\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i)
  end

  input :password do
    required(:password).filled(:string).min_size?(8)
  end

  input :age, optional: true do
    optional(:age).maybe(:integer, gt?: 0, lt?: 150)
  end
end
```

Or using a contract-style approach:

```ruby
class UserRegistration < RubyReactor::Reactor
  input :email, validate: Dry::Schema.Params do
    required(:email).filled(:string, :email?)
  end

  input :password, validate: Dry::Schema.Params do
    required(:password).filled(:string).min_size?(8)
  end
end
```

### 2. Step-Level Validations

Add validation support at the step level for validating step outputs:

```ruby
class UserRegistration < RubyReactor::Reactor
  step :create_user do
    argument :email, result(:validate_email)
    argument :password_hash, result(:hash_password)
    
    validate_output do
      required(:id).filled(:integer, gt?: 0)
      required(:email).filled(:string, :email?)
      required(:password_hash).filled(:string)
      required(:created_at).filled(:time)
    end
    
    run do |args, context|
      # step implementation
    end
  end
end
```

### 3. Conditional Validations with Guards

Extend the existing guard functionality to include validation:

```ruby
step :process_payment do
  argument :amount, input(:amount)
  argument :user, result(:validate_user)
  
  validate_args do
    required(:amount).filled(:decimal, gt?: 0)
    required(:user).hash do
      required(:id).filled(:integer)
      required(:verified).filled(:bool, eql?: true)
    end
  end
  
  guard do |args, context|
    # Additional business logic guards
    args[:user][:balance] >= args[:amount]
  end
end
```

### 4. Schema Inheritance and Reusability

Support schema composition and inheritance:

```ruby
module Schemas
  UserSchema = Dry::Schema.Params do
    required(:id).filled(:integer, gt?: 0)
    required(:email).filled(:string, :email?)
    optional(:name).maybe(:string)
  end
  
  PaymentSchema = Dry::Schema.Params do
    required(:amount).filled(:decimal, gt?: 0)
    required(:currency).filled(:string, included_in?: %w[USD EUR GBP])
  end
end

class PaymentProcessor < RubyReactor::Reactor
  input :user, validate: Schemas::UserSchema
  input :payment, validate: Schemas::PaymentSchema
  
  # or using a more declarative approach
  validate_inputs do
    user Schemas::UserSchema
    payment Schemas::PaymentSchema
  end
end
```

## Implementation Plan

### Phase 1: Core Integration

1. **Add dry-validation dependency**
   - Update gemspec with `dry-validation` and `dry-schema`
   - Update Gemfile for development dependencies

2. **Extend Input Declaration**
   - Modify `RubyReactor::Dsl::Reactor#input` to accept validation blocks
   - Create validation wrapper classes
   - Implement input validation in the executor

3. **Error Handling Integration**
   - Create `RubyReactor::Error::InputValidationError`
   - Integrate with existing error handling pipeline
   - Ensure proper error reporting with field-specific messages

### Phase 2: Step Validations

1. **Step Argument Validation**
   - Extend `StepBuilder` to support `validate_args` method
   - Implement pre-execution validation

2. **Step Output Validation**
   - Add `validate_output` method to `StepBuilder`
   - Implement post-execution validation

### Phase 3: Advanced Features

1. **Schema Composition**
   - Support for reusable schema modules
   - Schema inheritance and composition patterns

2. **Conditional Validations**
   - Context-aware validations
   - Integration with existing guard system

## Proposed File Structure

```
lib/ruby_reactor/
├── validation/
│   ├── base.rb                 # Base validation classes
│   ├── input_validator.rb      # Input validation logic
│   ├── step_validator.rb       # Step validation logic
│   └── schema_builder.rb       # Helper for building schemas
├── dsl/
│   ├── reactor.rb              # Enhanced with validation methods
│   ├── step_builder.rb         # Enhanced with validation methods
│   └── validation_helpers.rb   # DSL helpers for validation
└── error/
    └── input_validation_error.rb # New error class
```

## Usage Examples

### Basic Input Validation

```ruby
class CreateAccount < RubyReactor::Reactor
  input :user_data do
    required(:email).filled(:string, :email?)
    required(:password).filled(:string).min_size?(8)
    optional(:age).maybe(:integer, gteq?: 18)
  end

  step :create_user do
    argument :user_data, input(:user_data)
    
    run do |args, context|
      # user_data is guaranteed to be valid here
      Success(create_user_record(args[:user_data]))
    end
  end
end

# Usage
result = CreateAccount.run(
  user_data: {
    email: "test@example.com",
    password: "secretpassword",
    age: 25
  }
)
```

### Advanced Validation with Custom Rules

```ruby
class ProcessOrder < RubyReactor::Reactor
  input :order do
    required(:items).array(:hash) do
      required(:id).filled(:integer)
      required(:quantity).filled(:integer, gt?: 0)
      required(:price).filled(:decimal, gt?: 0)
    end
    required(:customer_id).filled(:integer)
    
    # Custom validation rule
    rule(:items) do
      key.failure('must have at least one item') if value.empty?
    end
  end

  step :validate_inventory do
    argument :items, input(:order)[:items]
    
    validate_output do
      required(:available).filled(:bool)
      optional(:unavailable_items).array(:integer)
    end
    
    run do |args, context|
      # Implementation here
    end
  end
end
```

### Conditional Validation

```ruby
class SubscriptionProcessor < RubyReactor::Reactor
  input :subscription_type, validate: Dry::Schema.Params do
    required(:subscription_type).filled(:string, included_in?: %w[free premium enterprise])
  end

  input :payment_info, optional: true do
    # Only validate payment info for paid subscriptions
    schema do
      optional(:payment_method).maybe(:hash) do
        required(:type).filled(:string)
        required(:token).filled(:string)
      end
    end
    
    # Custom conditional validation
    rule(:payment_method) do
      if context[:subscription_type] != 'free' && value.nil?
        key.failure('payment method required for paid subscriptions')
      end
    end
  end
end
```

## Benefits of This Approach

1. **Natural Integration**: Builds on existing DSL patterns
2. **Backward Compatibility**: Existing reactors continue to work unchanged  
3. **Flexibility**: Supports both simple and complex validation scenarios
4. **Performance**: Validation happens at optimal points in the pipeline
5. **Developer Experience**: Clear error messages with field-specific feedback
6. **Composability**: Reusable validation schemas across reactors

## Error Handling Enhancement

Validation errors will be wrapped in a structured format:

```ruby
# When validation fails
result = UserRegistration.run(email: "invalid", password: "123")

result.failure? # => true
result.error    # => RubyReactor::Error::InputValidationError

# Detailed error information
result.error.field_errors
# => {
#   email: ["is not a valid email format"],  
#   password: ["must be at least 8 characters"]
# }

result.error.message
# => "Input validation failed: email is not a valid email format, password must be at least 8 characters"
```

## Testing Strategy

The implementation will include comprehensive testing:

1. **Unit Tests**: Individual validation components
2. **Integration Tests**: Full reactor flows with validation
3. **Performance Tests**: Validation overhead measurement  
4. **Compatibility Tests**: Ensure backward compatibility

This approach provides a powerful, flexible validation system that feels natural within the Ruby Reactor ecosystem while leveraging the robust dry-ruby validation libraries.
