# Contract: Public API Surface Changes

These are the changes visible to gem users. No DSL keyword is added. The 2026-09-27 revision
removes three: `retries` on `compose`/`async_reactor`, `where` and `guard` (§1).

## 1. DSL

### `async_step`: rollback declarations

```ruby
async_step :notify, NotifyStep do
  argument :user_id, input(:user_id)
  compensate { |error, inputs, ctx| Audit.log_failed_notification(inputs.user_id) } # runs in the unit's job
  undo { |value, inputs, ctx| ... }   # => RubyReactor::Error::ValidationError at class definition
end
```

**Inline `undo` in `async_step`** raises `Error::ValidationError` when the class is defined. The
message names the step and explains:

- An `async_step` is independent. Its parent never undoes it.
- Cleanup for a surfaced failure belongs in the reading step's `compensate`.
- Cleanup that must run when the parent rolls back needs a construct the parent tracks: a `step`,
  a `compose` or a `map`.

**A step class that defines `undo`**, used with `async_step`: a warning goes out through the
existing definition-time warning channel (`StepBuilder#warn_deprecation`), once per reactor and
step. It says the class's `undo` will not run for this async use. There is no error.

**`compensate` in `async_step`** (inline or class) runs **once**, in the unit's own job, after the
body's final attempt fails. It does not run on attempts that are retried, on `Halt`, or on
never-started failures.

### `map`: no DSL change

Rollback replays the `undo` blocks already declared on the element reactor's steps.

### Removed: `retries` on `compose` / `async_reactor` (R-14)

```ruby
compose :reserve, ReservationReactor do
  retries max_attempts: 3   # => RubyReactor::Error::DeprecatedDslError at class definition
end
```

The message names the step and says to declare `retries` on the child reactor's own steps. The same
applies inside an inline `compose` block and in an `async_reactor` block. Without `retries`, both
constructs run their child exactly once per parent step.

### Removed: `where` / `guard` (R-15)

```ruby
step :sync_user, SyncUserStep do
  where { |ctx| ctx.get_input(:enabled) }   # => RubyReactor::Error::DeprecatedDslError
end
```

The message names the step and says to return `Skipped(value)` (or call `skip!`) from the step
body. It applies to `step`, `async_step` and `interrupt` blocks.

### `Skipped`: meaning defined (R-17)

`Skipped` is only an instrumentation mark. In every effect it is a `Success`: enrolled for undo (a
later failure runs its `undo` with the skipped value), a `background after:` hand-off fires, and a
`with_period` bucket is marked. (Before: never undone, no `after:` hand-off, no period mark.)

## 2. Errors (`RubyReactor::Error`)

| Class | Parent | Raised by | Carried on the Failure as |
| --- | --- | --- | --- |
| `ArgumentResolutionError` (new) | `Error::Base` | a step's `argument` source, `transform` or result path raising | `step_name`, `exception_class` = the cause's class, `retryable: false` |
| `Rescuable` (new, a matcher module, not an exception class) | — | used in `rescue Error::Rescuable` | matches every `Exception` except `SignalException`, `SystemExit`, `NoMemoryError`, `Timeout::ExitException` |

`ArgumentResolutionError` does not propagate out of `Reactor.run`. The run returns a `Failure` as
for any step failure. (`ConditionError` from the first implementation is removed, R-15.)

## 3. `RubyReactor::Failure`

| Path | Before | After |
| --- | --- | --- |
| argument resolution raises | `"Execution failed: <msg>"`, no `step_name`, nothing rolled back | step failure message, `step_name`, `reactor_name`, `step_arguments: {}`, completed steps undone |
| unknown exception outside a step body (standard or not, except interruptions) | `"Execution failed: <msg>"`, no rollback | completed steps undone. `step_name` = the executing step when known |
| non-`StandardError` raised by a step body (e.g. `NotImplementedError`, custom `Exception`) | propagated out of `Reactor.run`, no rollback | returned as the step's `Failure`: step compensated, completed steps undone, `exception_class` = the original class |
| compensation of the failing step fails (`CompensationError`) | `"Execution error: <msg>"`, no `step_name` | same message, `step_name` set |

### `rollback_failures` entries

The existing keys are `step`, `kind`, `key`, `reason` and `message`. New optional keys:

- `map_step`: Symbol
- `element_index`: Integer

New `reason` values:

- `:context_unavailable`: an element context expired before rollback
- `:element_in_flight`: the element was still running at rollback time

## 4. Execution status

- **New status `aborted`**:
  - Readable on the stored context: `status`, dashboard, web API.
  - Set only for executions in the caller's process that are cut short by an interruption
    (`SignalException`, `SystemExit`, `NoMemoryError`, `Timeout::ExitException`). The exception is
    re-raised unchanged. Its stored undo stack holds only the entries not yet undone.
  - The reactor `Sweeper` does not resume aborted executions.
  - `Reactor#undo` (manual undo) rolls them back.
- **Dashboard and web API**:
  - `aborted` is accepted in status filters and shown like the other terminal-looking states.
  - It is not grouped with `failed`, because no rollback ran.

## 5. Stored records

- **Async step result record**: gains `compensation: { status, rollback_failures, completed_at }`
  when the unit's compensate ran (data-model §8).
- **Map results hash**: an index can hold `{ "_skipped" => true }`. `ResultEnumerator` never yields
  skipped slots. They exist only on a failed fail-fast map, which is never collected as a success.

## 6. Middleware events

No new event names. Changes in when existing events fire:

- `start_compensation` / `complete_compensation` / `failed_compensation` now fire in the async step
  unit's job, with the unit's context and step name.
- `start_undo` / `complete_undo` / `failed_undo` fire for each element step undone by a map
  rollback, with the **element's** context.
- `failed_step` for argument-resolution failures now carries the step name, like any step failure.
