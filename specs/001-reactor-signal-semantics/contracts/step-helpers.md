# Contract: Step Outcome Helpers

Four helpers that produce a signal **and end the step immediately**.

```ruby
success!(value = nil)          # → Success(value)
skip!(value = nil)             # → Skipped(value)
fail!(error, retry: true)      # → Failure(error, retry:)
halt!(reason: nil)             # → Halt(reason:)
```

## Both authoring styles

Inline block:

```ruby
step :onboard do
  argument :user, input(:user)
  run do |args|
    success!(user: args[:user]) if args[:user].ready?

    action = do_something(args[:user])
    fail!(action.errors) unless action.success?

    Success(action.result)
  end
end
```

Class step:

```ruby
class MyStep
  include RubyReactor::Step

  def self.run(args, context)
    success!(user: args[:user]) if args[:user].ready?

    action = do_something(args[:user])
    fail!(action.errors) unless action.success?

    Success(action.result)
  end
end
```

Behaviour is identical in both.

## Guarantees

1. **Nothing after the call runs.** The helper unwinds the step body.
2. **Any depth works.** A helper called from a method the step body invokes,
   however deep, ends the step:

   ```ruby
   def self.run(args, context)
     check!(args)          # calls fail! inside
     Success(:never_reached_if_check_failed)
   end

   def self.check!(args)
     fail!("nope") unless args[:ok]
   end
   ```

3. **Broad rescues cannot swallow it.** The unwind is a `throw`, not an
   exception, so `rescue StandardError` and even `rescue Exception` inside the
   step body do not intercept it. `ensure` blocks still run.
4. **Returning a signal still works.** `return Success(x)` / falling off the end
   with a signal behaves exactly as before. The helpers are additive.
5. **Available in compensation and undo bodies**, not only in `run`.

## Equivalences

| Helper call | Equivalent return |
|---|---|
| `success!(v)` | `return Success(v)` |
| `skip!(v)` | `return Skipped(v)` |
| `fail!(e)` | `return Failure(e)` |
| `fail!(e, retry: false)` | `return Failure(e, retry: false)` |
| `halt!(reason: r)` | `return Halt(reason: r)` |

The executor cannot tell the two forms apart — same signal object, same
downstream handling, same trace entries.

## Boundaries

- A helper called **outside** a step body (no enclosing catch) raises
  `UncaughtThrowError`. This is a programming error, not a supported mode.
- `skip!(reason: "x")` is rejected by the `Skipped` migration guard. Pass an
  explicit hash — `skip!({ reason: "x" })` — if that hash is genuinely the value
  you want dependants to receive.
- The helpers do not swallow errors: an exception raised before the helper call
  still becomes a `Failure` through the existing error path.
