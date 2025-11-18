# RubyReactor

A dynamic, dependency-resolving saga orchestrator for Ruby. Ruby Reactor implements the Saga pattern with compensation-based error handling and DAG-based execution planning.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'ruby_reactor'
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install ruby_reactor

## Usage

RubyReactor allows you to define complex workflows as "reactors" with steps that can depend on each other, handle failures with compensations, and validate inputs.

### Basic Example: User Registration

```ruby
require 'ruby_reactor'

class UserRegistrationReactor < RubyReactor::Reactor
  # Define inputs with optional validation
  input :email
  input :password

  # Define steps with their dependencies
  step :validate_email do
    argument :email, input(:email)

    run do |args, context|
      if args[:email] && args[:email].include?('@')
        Success(args[:email].trim)
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
    # Arguments can reference results from other steps
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

    conpensate do |error, args, context|
      Notify.to(args[:email])
    end
  end

  step :notify_user do
    argument :email, result(:validate_email)
    wait_for :create_user

    run do |args, _context| 
      Email.sent!(args[:email], "verify your email")
      Success()
    end

    compensate do |error, args, context|
      Email.send("support@acme.com", "Email verification for #{args[:email]} couldn't be sent")
      Success()
    end
  end
  # Specify which step's result to return
  returns :create_user
end

# Run the reactor
result = UserRegistrationReactor.run(
  email: 'alice@example.com',
  password: 'secret123'
)

if result.success?
  puts "User created: #{result.value[:email]}"
else
  puts "Failed: #{result.error}"
end
```

### Input Validation

RubyReactor integrates with dry-validation for input validation:

```ruby
class ValidatedUserReactor < RubyReactor::Reactor
  input :name do
    required(:name).filled(:string, min_size?: 2)
  end

  input :email do
    required(:email).filled(:string)
  end

  input :age do
    required(:age).filled(:integer, gteq?: 18)
  end

  # Optional inputs
  input :bio, optional: true do
    optional(:bio).maybe(:string, max_size?: 100)
  end

  step :create_profile do
    argument :name, input(:name)
    argument :email, input(:email)
    argument :age, input(:age)
    argument :bio, input(:bio)

    run do |args, context|
      profile = {
        name: args[:name],
        email: args[:email],
        age: args[:age],
        bio: args[:bio] || "No bio provided",
        created_at: Time.now
      }
      Success(profile)
    end
  end

  returns :create_profile
end

# Valid input
result = ValidatedUserReactor.run(
  name: "Alice Johnson",
  email: "alice@example.com",
  age: 25,
  bio: "Software developer"
)

# Invalid input - will return validation errors
result = ValidatedUserReactor.run(
  name: "A",  # Too short
  email: "",  # Empty
  age: 15     # Too young
)
```

### Complex Workflows with Dependencies

Steps can depend on results from multiple other steps:

```ruby
class OrderProcessingReactor < RubyReactor::Reactor
  input :user_id
  input :product_ids, validate: ->(ids) { ids.is_a?(Array) && ids.any? }

  step :validate_user do
    argument :user_id, input(:user_id)

    run do |args, context|
      # Check if user exists and has permission to purchase
      user = find_user(args[:user_id])
      user ? Success(user) : Failure("User not found")
    end
  end

  step :validate_products do
    argument :product_ids, input(:product_ids)

    run do |args, context|
      products = args[:product_ids].map { |id| find_product(id) }
      if products.all?
        Success(products)
      else
        Failure("Some products not found")
      end
    end
  end

  step :calculate_total do
    argument :products, result(:validate_products)

    run do |args, context|
      total = args[:products].sum { |p| p[:price] }
      Success(total)
    end
  end

  step :check_inventory do
    argument :products, result(:validate_products)

    run do |args, context|
      available = args[:products].all? { |p| p[:stock] > 0 }
      available ? Success(true) : Failure("Out of stock")
    end
  end

  step :process_payment do
    argument :user, result(:validate_user)
    argument :total, result(:calculate_total)

    run do |args, context|
      # Process payment logic here
      payment_id = process_payment(args[:user][:id], args[:total])
      Success(payment_id)
    end

    undo do |error, args, context|
      # Refund payment on failure
      refund_payment(args[:payment_id])
      Success()
    end
  end

  step :create_order do
    argument :user, result(:validate_user)
    argument :products, result(:validate_products)
    argument :payment_id, result(:process_payment)

    run do |args, context|
      order = create_order_record(args[:user], args[:products], args[:payment_id])
      Success(order)
    end

    undo do |error, args, context|
      # Cancel order and update inventory
      cancel_order(args[:order][:id])
      Success()
    end
  end

  step :update_inventory do
    argument :products, result(:validate_products)

    run do |args, context|
      args[:products].each { |p| decrement_stock(p[:id]) }
      Success(true)
    end

    undo do |error, args, context|
      # Restock products
      args[:products].each { |p| increment_stock(p[:id]) }
      Success()
    end
  end

  step :send_confirmation do
    argument :user, result(:validate_user)
    argument :order, result(:create_order)

    run do |args, context|
      send_email(args[:user][:email], "Order confirmed", order_details(args[:order]))
      Success(true)
    end
  end

  returns :send_confirmation
end
```

### Error Handling and Compensation

When a step fails, RubyReactor automatically undoes completed steps in reverse order, compensate only runs in the failing step and backwalks the executed steps undo blocks:

```ruby
class TransactionReactor < RubyReactor::Reactor
  input :from_account
  input :to_account
  input :amount

  step :validate_accounts do
    argument :from_account, input(:from_account)
    argument :to_account, input(:to_account)

    run do |args, context|
      from = find_account(args[:from_account])
      to = find_account(args[:to_account])

      if from && to && from != to
        Success({from: from, to: to})
      else
        Failure("Invalid accounts")
      end
    end
  end

  step :check_balance do
    argument :accounts, result(:validate_accounts)
    argument :amount, input(:amount)

    run do |args, context|
      if args[:accounts][:from][:balance] >= args[:amount]
        Success(args[:accounts])
      else
        Failure("Insufficient funds")
      end
    end
  end

  step :debit_account do
    argument :accounts, result(:check_balance)
    argument :amount, input(:amount)

    run do |args, context|
      debit(args[:accounts][:from][:id], args[:amount])
      Success(args[:accounts])
    end

    undo do |error, args, context|
      # Credit the amount back
      credit(args[:accounts][:from][:id], args[:amount])
      Success()
    end
  end

  step :credit_account do
    argument :accounts, result(:debit_account)
    argument :amount, input(:amount)

    run do |args, context|
      credit(args[:accounts][:to][:id], args[:amount])
      Success({transaction_id: generate_transaction_id()})
    end

    undo do |error, args, context|
      # Debit the amount back from recipient
      debit(args[:accounts][:to][:id], args[:amount])
      Success()
    end
  end

  step :notify do
    argument :accounts, result(:validate_accounts)
    wait_for :credit_account, :debit_account

    run do |args, context|
      Notify.to(args[:accounts][:from])
      Notify.to(args[:accounts][:to])
    end
     
  end

  returns :credit_account
end

# If credit_account fails, RubyReactor will:
# 1. Compensate credit_account (debit the recipient)
# 2. Undo debit_account (credit the sender)
# Result: Complete rollback of the transaction
```

### Using Pre-defined Schemas

You can use existing dry-validation schemas:

```ruby
require 'dry/schema'

user_schema = Dry::Schema.Params do
  required(:user).hash do
    required(:name).filled(:string, min_size?: 2)
    required(:email).filled(:string)
    optional(:phone).maybe(:string)
  end
end

class SchemaValidatedReactor < RubyReactor::Reactor
  input :user, validate: user_schema

  step :process_user do
    argument :user, input(:user)

    run do |args, context|
      Success(args[:user])
    end
  end

  returns :process_user
end
```

## Documentation

For detailed documentation, see the following guides:

### Core Documentation
- [Getting Started](documentation/getting_started.md) - Introduction and setup guide
- [Core Concepts](documentation/core_concepts.md) - Understanding reactors, steps, and execution flow
- [DAG (Directed Acyclic Graph)](documentation/DAG.md) - How RubyReactor manages dependencies and execution order
- [Async Reactors](documentation/async_reactors.md) - Working with asynchronous operations
- [Retry Configuration](documentation/retry_configuration.md) - Configuring retry behavior and failure handling

### Examples
- [Order Processing](documentation/examples/order_processing.md) - Complete order processing workflow example
- [Payment Processing](documentation/examples/payment_processing.md) - Payment handling with compensation
- [Inventory Management](documentation/examples/inventory_management.md) - Inventory management system example

## Future improvements

- [X] Global id to serialize ActiveRecord classes
- [ ] Middlewares
- [ ] Descriptive errors
- [ ] `map` step to iterate over arrays in parallel
- [ ] `compose` special step to execute reactors as step
- [ ] Async ruby to parallelize same level steps
- [ ] Dedicated interface to inspect reactor results and errors

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/arturictus/ruby_reactor. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/arturictus/ruby_reactor/blob/main/CODE_OF_CONDUCT.md).

## Code of Conduct

Everyone interacting in the RubyReactor project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/arturictus/ruby_reactor/blob/main/CODE_OF_CONDUCT.md).
