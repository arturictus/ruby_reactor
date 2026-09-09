# Contract: Signal Public API

Public surface of `RubyReactor` after this feature. Everything here is part of
the gem's semver contract.

## Builders

```ruby
RubyReactor.Success(value = nil)          # unchanged
RubyReactor.Failure(error, **opts)        # + retry: alias (see below)
RubyReactor.Skipped(value = nil)          # NEW MEANING: step skipped, reactor continues
RubyReactor.Halt(reason: nil, **kwargs)   # NEW NAME: old Skipped behaviour
```

Available unqualified inside reactor definitions and step classes:
`Success()`, `Failure()`, `Skipped()`, `Halt()`.

## Predicates

| | `success?` | `failure?` | `skipped?` | `halted?` | `retryable?` |
|---|---|---|---|---|---|
| `Success` | true | false | false | false | — |
| `Skipped` | true | false | **true** | false | — |
| `Halt` | true | false | **(not defined)** | **true** | — |
| `Failure` | false | true | false | false | per flag |

`Halt` deliberately does not respond to `skipped?`. Any migration site that
still asks a halt whether it was skipped raises `NoMethodError` instead of
reading a plausible `false`.

## `Skipped` — step skipped, reactor continues

```ruby
step :maybe_sync do
  run do |args|
    Skipped(args[:user]) if args[:user].already_synced?
    Success(sync!(args[:user]))
  end
end

step :notify do
  argument :user, result(:maybe_sync)   # receives the user either way
  run { |args| Success(mail(args[:user])) }
end
```

- The value is stored as the step's result and is indistinguishable to
  dependants from a `Success` value.
- The step is marked complete in the dependency graph; dependants become ready.
- The step is **not** pushed to the undo stack — a later failure does not roll
  it back.
- The step's declared output validation still applies to the value.

**Migration guard**: `Skipped(reason: "…")` — the old halt call shape — raises
`ArgumentError`:

```
RubyReactor::Skipped now marks a single step as skipped and continues.
The clean halt you want is RubyReactor.Halt(reason: ...) / halt!(reason: ...).
```

## `Halt` — stop the reactor, keep progress, no rollback

```ruby
step :check_opt_out do
  run do |args|
    Halt(reason: "user opted out") if args[:user].opted_out?
    Success(args[:user])
  end
end
```

Identical in every observable way to the signal previously named `Skipped`:
no further steps run, no compensation or undo of completed steps, the caller
receives the halt with its `reason` and the halting `step_name`.

Internal producers, unchanged except for the name: the `with_period` gate
(`reason: :period`, plus `period_key`) and the ordered-lock gates
(`:ordered_lock_stale_batch`, `:ordered_lock_drained_replay`,
`:ordered_lock_chain_failed`).

## `Failure` — retry flag

```ruby
Failure(error)                  # retry allowed (default, unchanged)
Failure(error, retry: false)    # terminal on the first attempt
Failure(error, retryable: false) # still accepted — same thing
```

- `retry:` and `retryable:` are the same flag. When both appear, `retry:` wins.
- The flag is a **veto only**. A step that declares no retry configuration, or
  that has spent its attempt budget, is not retried whatever the flag says.
- `retry: false` means: no further attempt, no backoff sleep, no re-enqueue —
  straight to compensation and rollback.
- The flag survives serialization into and out of background execution.

## Retry participation

| Signal | Enters the retry machinery |
|---|---|
| `Success` | no |
| `Skipped` | no |
| `Halt` | no |
| `Failure` | yes, subject to the veto and the step's budget |

A step that emits `Success`, `Skipped`, or `Halt` after earlier failed attempts
clears its accumulated retry state and reports that outcome — never a
retry-exhaustion failure.

## Compensation and undo defaults

```ruby
class MyStep
  include RubyReactor::Step
  # no compensate / undo defined  →  both report Skipped during rollback
end
```

A skipped compensation or undo is **not** a failure: rollback continues exactly
as it does for a successful one. Authors who define compensation get their own
result recorded, so the trace distinguishes "ran" from "never written".

## Breaking changes

| Before | After |
|---|---|
| `Skipped(reason:)` halts the reactor | `Halt(reason:)` halts; `Skipped(value)` skips one step and continues |
| `result.skipped?` means the run halted | `result.halted?` means the run halted; `skipped?` means one step was skipped |
| run status `:skipped` | run status `:halted` (legacy `"skipped"` still read from storage) |
| `compensate`/`undo` default to `Success` | they default to `Skipped` |
| matcher `be_skipped` asserts a clean halt | matcher `be_halted` asserts a clean halt |
