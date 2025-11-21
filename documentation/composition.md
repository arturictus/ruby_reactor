# Composition

RubyReactor allows you to compose reactors within other reactors using the `compose` DSL. This enables you to build complex workflows by reusing existing reactors or defining sub-workflows inline.

## Inline Composition

You can define a composed reactor inline using a block. This is useful for grouping related steps or defining a sub-workflow that doesn't need to be reused elsewhere.

```ruby
class UpdateUserReactor < RubyReactor::Reactor
  input :user_id
  input :profile_data

  step :validate_user do
    argument :user_id, input(:user_id)
    run { |args| ... }
  end

  # Define a sub-workflow inline
  compose :update_profile do
    # You can define inputs for the inline reactor
    argument :user_id, input(:user_id)
    argument :data, input(:profile_data)

    # Configure async execution for the sub-workflow
    async true
    
    # Configure retries for steps within the sub-workflow
    retries max_attempts: 3

    step :update_bio do
      argument :user_id, input(:user_id)
      argument :bio, input(:data, :bio)
      run { |args| ... }
    end

    step :update_avatar do
      argument :user_id, input(:user_id)
      argument :avatar, input(:data, :avatar)
      run { |args| ... }
    end
  end

  step :notify_user do
    wait_for :update_profile
    run { |args| ... }
  end
end
```

## Class-based Composition

You can also compose an existing reactor class. This is ideal for reusable workflows.

```ruby
class ProfileUpdateReactor < RubyReactor::Reactor
  input :user_id
  input :data
  
  step :update_bio do ... end
  step :update_avatar do ... end
end

class MainReactor < RubyReactor::Reactor
  input :user_id
  input :profile_data

  # Compose the existing reactor
  compose :update_profile, ProfileUpdateReactor do
    argument :user_id, input(:user_id)
    argument :data, input(:profile_data)
  end
end
```

## Multiple Compose Declarations

A single reactor can include multiple `compose` declarations, allowing you to orchestrate several sub-workflows. You can mix both class-based and inline compositions, and combine them with regular steps.

```ruby
class OrderProcessingReactor < RubyReactor::Reactor
  input :order_id
  input :customer_data
  input :payment_info

  step :validate_order do
    argument :order_id, input(:order_id)
    run { |args| ... }
  end

  # First compose: Class-based reactor
  compose :update_customer_profile, CustomerProfileReactor do
    argument :customer_data, input(:customer_data)
  end

  # Second compose: Inline reactor
  compose :process_payment do
    argument :order_id, input(:order_id)
    argument :payment_info, input(:payment_info)
    
    async true  # This sub-workflow can run async
    
    step :authorize_payment do
      run { |args| ... }
    end
    
    step :capture_payment do
      run { |args| ... }
    end
  end

  # Third compose: Another inline reactor
  compose :allocate_inventory do
    argument :order_id, input(:order_id)
    argument :order, input(:validate_order)
    
    step :check_availability do
      run { |args| ... }
    end
    
    step :reserve_items do
      run { |args| ... }
    end
  end

  step :send_confirmation do
    # Wait for all compose steps to complete
    wait_for :update_customer_profile, :process_payment, :allocate_inventory
    
    argument :customer_email, input(:customer_data)
    argument :order_id, input(:order_id)
    run { |args| ... }
  end
end
```

### Execution Flow

When you have multiple `compose` declarations:

1. **Execution Order**: Composed reactors execute in topological order based on their dependencies. Dependencies are determined automatically when you reference results from other steps (using `result(:step_name)`), or explicitly using `wait_for`. If no dependencies exist.

2. **Access Compose Results**: A compose step returns the final result of the composed reactor. By default, this is a hash containing all of its step results, unless the composed reactor uses the `returns` DSL to specify a custom return value:

```ruby
step :final_step do
  # Get the complete result hash from the composed reactor
  argument :payment_result, result(:process_payment)
  
  run { |args| 
    # args[:payment_result] contains the full hash: 
    # { authorize_payment: ..., capture_payment: ... }
    # 
    # args[:payment_status] contains just the capture_payment result
  }
end
```

3. **Async Execution**: If a composed reactor is marked with `async true`, execution will pause at that compose step, serialize the entire reactor context, and queue a background job. The worker will resume execution from that compose step and continue sequentially through remaining steps. Only one worker executes the main reactor at a time.

4. **Shared Context**: All composed reactors share access to the parent reactor's inputs and results of previous steps and can be configured with different retry strategies.

### Async Compose Execution Flow

When you mark a compose as async:

```ruby
compose :process_payment do
  async true
  # ... steps
end
```

The execution flow is:

1. Parent reactor executes steps up to `process_payment`
2. Serializes entire context and queues a background job
3. Returns `AsyncResult` to caller
4. Worker picks up job and resumes from `process_payment`
5. After `process_payment` completes, continues to next step sequentially
6. If another async step is encountered, the process repeats

This ensures proper ordering and state consistency across async boundaries.

## Nested Async Retries

One of the powerful features of composition in RubyReactor is the handling of asynchronous retries within nested reactors.

When a step inside a composed reactor fails and is configured to retry asynchronously (e.g., via Sidekiq), RubyReactor ensures that the entire execution context is preserved.

1.  **Context Serialization**: The entire reactor tree, including the state of the parent reactor and the composed reactor, is serialized.
2.  **Resume on Retry**: When the retry job executes, it resumes execution exactly from the failed step within the composed reactor.
3.  **State Preservation**: All intermediate results and inputs from the parent reactor are available, ensuring that the composed reactor has everything it needs to complete.

This behavior works seamlessly whether you are using inline composition or class-based composition.

## Inspection

The execution state of composed reactors is stored in the parent context under `composed_contexts`. This allows for inspection of the full execution tree, which is useful for debugging and building monitoring tools.
