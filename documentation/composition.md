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

## Nested Async Retries

One of the powerful features of composition in RubyReactor is the handling of asynchronous retries within nested reactors.

When a step inside a composed reactor fails and is configured to retry asynchronously (e.g., via Sidekiq), RubyReactor ensures that the entire execution context is preserved.

1.  **Context Serialization**: The entire reactor tree, including the state of the parent reactor and the composed reactor, is serialized.
2.  **Resume on Retry**: When the retry job executes, it resumes execution exactly from the failed step within the composed reactor.
3.  **State Preservation**: All intermediate results and inputs from the parent reactor are available, ensuring that the composed reactor has everything it needs to complete.

This behavior works seamlessly whether you are using inline composition or class-based composition.

## Inspection

The execution state of composed reactors is stored in the parent context under `composed_contexts`. This allows for inspection of the full execution tree, which is useful for debugging and building monitoring tools.
