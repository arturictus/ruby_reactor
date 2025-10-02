# Working Dry-Ruby Validation Integration Example

This document demonstrates the successful integration of dry-ruby validation into Ruby Reactor. The implementation provides a natural DSL extension that maintains backward compatibility while adding powerful validation capabilities.

## Implementation Summary

✅ **Core Integration Complete**
- Input validation using dry-schema blocks
- Automatic validation error handling  
- Backward compatibility maintained
- Clean DSL extension

## Working Examples

### 1. Basic Input Validation

```ruby
class UserRegistration < RubyReactor::Reactor
  input :name do
    required(:name).filled(:string, min_size?: 2)
  end

  input :age do 
    required(:age).filled(:integer, gteq?: 18)
  end

  step :create_user do
    argument :name, input(:name)
    argument :age, input(:age)
    
    run do |args, context|
      user = {
        name: args[:name],
        age: args[:age], 
        created_at: Time.now
      }
      Success(user)
    end
  end

  returns :create_user
end

# Usage with valid data
result = UserRegistration.run(name: "Alice", age: 25)
# => Success({name: "Alice", age: 25, created_at: ...})

# Usage with invalid data
result = UserRegistration.run(name: "A", age: 15) 
# => Failure("Input validation failed: name size cannot be less than 2, age must be greater than or equal to 18")
```

### 2. Optional Fields with Validation

```ruby
class ProfileUpdate < RubyReactor::Reactor
  input :name do
    required(:name).filled(:string, min_size?: 2)
  end

  input :bio, optional: true do
    optional(:bio).maybe(:string, max_size?: 500)
  end

  input :age, optional: true do
    optional(:age).maybe(:integer, gteq?: 13, lteq?: 120)
  end

  step :update_profile do
    argument :name, input(:name)
    argument :bio, input(:bio)
    argument :age, input(:age)
    
    run do |args, context|
      profile = args.compact
      Success(profile)
    end
  end

  returns :update_profile
end
```

### 3. Using Pre-defined Schemas

```ruby
# Define reusable schemas
UserSchema = Dry::Schema.Params do
  required(:name).filled(:string, min_size?: 2)
  required(:email).filled(:string)
  optional(:phone).maybe(:string)
end

class CreateAccount < RubyReactor::Reactor
  input :user, validate: UserSchema

  step :create_account do
    argument :user, input(:user)
    
    run do |args, context|
      account = {
        id: SecureRandom.uuid,
        **args[:user],
        created_at: Time.now
      }
      Success(account)
    end
  end

  returns :create_account
end
```

## Key Features Implemented

### 1. **Natural DSL Integration**
- Validation blocks feel natural within the existing `input` declaration
- Backward compatible - existing reactors work unchanged
- Optional validation - only applied when explicitly declared

### 2. **Rich Validation Support**  
- Full dry-schema validation capabilities
- Type validation (string, integer, float, etc.)
- Size constraints (min_size?, max_size?)
- Range constraints (gteq?, lteq?, gt?, lt?)
- Format validation, presence checks, and more

### 3. **Comprehensive Error Handling**
- Structured error messages with field-specific details
- Multiple validation error accumulation
- Integration with existing Ruby Reactor error pipeline

### 4. **Flexible Implementation Options**

**Option 1: Inline validation blocks**
```ruby
input :email do
  required(:email).filled(:string)
end
```

**Option 2: Pre-defined schemas**
```ruby
input :user, validate: UserSchema
```

**Option 3: Optional fields**
```ruby
input :bio, optional: true do
  optional(:bio).maybe(:string, max_size?: 500)
end
```

## Error Handling Examples

### Detailed Field Errors
```ruby
result = UserRegistration.run(name: "A", age: 15)

result.failure? # => true
result.error    # => RubyReactor::Error::InputValidationError

# Access structured error data
result.error.field_errors
# => { 
#   name: "size cannot be less than 2",
#   age: "must be greater than or equal to 18" 
# }

result.error.message
# => "Input validation failed: name size cannot be less than 2, age must be greater than or equal to 18"
```

## Architecture Benefits

### 1. **Performance Optimized**
- Validation occurs at optimal points in the pipeline
- Early failure detection prevents unnecessary processing
- Minimal overhead when validation is not used

### 2. **Developer Experience**
- Clear, structured error messages
- IntelliSense-friendly API
- Familiar dry-schema syntax

### 3. **Maintainability**
- Reusable validation schemas
- Separation of validation logic from business logic
- Easy testing of validation rules

## Testing Integration

The validation system integrates seamlessly with existing testing approaches:

```ruby
RSpec.describe UserRegistration do
  it "validates required fields" do
    result = UserRegistration.run(name: "", age: 10)
    
    expect(result).to be_failure
    expect(result.error.field_errors).to include(:name, :age)
  end

  it "processes valid data successfully" do
    result = UserRegistration.run(name: "Alice", age: 25)
    
    expect(result).to be_success
    expect(result.value[:name]).to eq("Alice")
  end
end
```

## Implementation Status

- ✅ Core validation infrastructure
- ✅ Input-level validation with dry-schema
- ✅ Error handling and reporting
- ✅ Backward compatibility
- ✅ Optional field support
- ✅ Pre-defined schema support
- ⚠️  Step-level validation (basic structure in place)
- ⚠️  Output validation (basic structure in place)

## Future Enhancements

1. **Step Validation**: Complete implementation of argument and output validation within steps
2. **Conditional Validation**: Context-aware validation rules
3. **Custom Validators**: Easy integration of custom validation logic
4. **Performance Optimizations**: Caching and lazy loading of schemas
5. **Documentation**: Comprehensive API documentation and usage guides

## Conclusion

The dry-ruby validation integration provides a powerful, flexible, and natural way to add robust input validation to Ruby Reactor workflows. The implementation maintains the clean DSL aesthetic while providing enterprise-grade validation capabilities that scale from simple field checks to complex business rules.