# Contract: Public API Surface Changes

These are the changes visible to gem users. No DSL keyword is added or removed.

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

### `map`, `compose`: no DSL change

- **Map**: rollback replays the `undo` blocks already declared on the element reactor's steps.
- **Compose**: retries re-run the whole child.

## 2. Errors (`RubyReactor::Error`)

| Class | Parent | Raised by | Carried on the Failure as |
| --- | --- | --- | --- |
| `ArgumentResolutionError` (new) | `Error::Base` | a step's `argument` source, `transform` or result path raising | `step_name`, `exception_class` = the cause's class, `retryable: false` |
| `ConditionError` (new) | `Error::Base` | a `where`/`guard` raising | same |

Neither class propagates out of `Reactor.run`. The run returns a `Failure` as for any step failure.

## 3. `RubyReactor::Failure`

| Path | Before | After |
| --- | --- | --- |
| argument resolution raises | `"Execution failed: <msg>"`, no `step_name`, nothing rolled back | step failure message, `step_name`, `reactor_name`, `step_arguments: {}`, completed steps undone |
| condition raises | step compensated | step **not** compensated. Otherwise as before |
| unknown `StandardError` outside a step body | `"Execution failed: <msg>"`, no rollback | completed steps undone. `step_name` = the executing step when known |
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
  - Set only for executions in the caller's process that are cut short by a
    non-`StandardError` exception. The exception is re-raised unchanged.
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
- **Parent `execution_trace`**: gains `type: :compose_attempt_discarded` entries (data-model §7).

## 6. Middleware events

No new event names. Changes in when existing events fire:

- `start_compensation` / `complete_compensation` / `failed_compensation` now fire in the async step
  unit's job, with the unit's context and step name.
- `start_undo` / `complete_undo` / `failed_undo` fire for each element step undone by a map
  rollback, with the **element's** context.
- `failed_step` for argument-resolution and condition failures now carries the step name, like
  any step failure.
