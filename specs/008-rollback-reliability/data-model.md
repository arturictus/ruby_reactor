# Data Model: Reliable Rollback Across Constructs

These are the records and state this feature adds or changes. The existing shapes are in
`lib/ruby_reactor/context.rb` (context blob) and `lib/ruby_reactor/storage/redis_adapter.rb`
(map and step records). Decisions are referenced as `R-nn` ([research.md](research.md)).

## 1. Construct (step config): lifecycle operations (R-01)

`StepConfig` is the step as declared in a reactor. Behavior only, nothing is stored.

| Operation | Returns / raises | Notes |
| --- | --- | --- |
| `resolve_arguments(context)` | `Hash` of resolved arguments. Raises `Error::ArgumentResolutionError` on any `StandardError`, except `Error::ExecutionParked` and its subclasses, which propagate | Replaces `StepExecutor#resolve_arguments` and `StepWorker#resolve_arguments` |
| `should_run?(context)` | `true`/`false`. Raises `Error::ConditionError` when a `where`/`guard` raises | Same predicate as today |
| `call_body(arguments, context)` | step result (exists) | unchanged |
| `call_compensate(error, arguments, context)` | step result | Dispatch order: inline block, then impl `.compensate`, then `Skipped`. Moved out of `CompensationManager` |
| `call_undo(result_value, arguments, context)` | step result | Dispatch order: inline block, then impl `.undo`, then `Skipped` |
| `rollback_tracked?` | `true` unless `async_dispatch?` | `ResultHandler` pushes a success only when this is true |

Coordination re-take, trace entries, middleware events and `rollback_failures` stay in
`CompensationManager`, which wraps these calls.

## 2. Never-started errors (R-06)

| Class | Parent | Attributes | Retryable |
| --- | --- | --- | --- |
| `Error::ArgumentResolutionError` | `Error::Base` | `step`, `original_error`, `exception_class` (the cause's class name), `message` | no |
| `Error::ConditionError` | `Error::Base` | same | no |

`CompensationManager::NEVER_STARTED_ERROR_CLASSES` becomes `Contended`, `KeyError`,
`DispatchRefused`, `ArgumentResolutionError`, `ConditionError`.

**Rule**: a failure whose error is in this set is not compensated, and the completed steps are
undone.

## 3. Context status (R-08)

| Status | Meaning | Set by | Terminal for `Worker`? | Swept? |
| --- | --- | --- | --- | --- |
| `pending`, `running`, `paused`, `completed`, `failed`, `halted`, `cancelled` | unchanged | unchanged | unchanged | only `running` |
| **`aborted`** (new) | An execution in the caller's process was cut short by a non-`StandardError` exception. Its completed work is still outstanding, and `undo_stack` is kept | `Executor#execute`/`#resume_execution` `rescue Exception`, when `!inline_async_execution` | not resumed forward (only a manual undo applies) | no |

State transitions:

```text
running --(non-StandardError, caller process)--> aborted --(Reactor#undo)--> cancelled
running --(non-StandardError, worker)----------> running (job redelivered, unchanged)
```

## 4. Undo record (context `undo_stack` entry)

The shape is unchanged: `{ step_name, arguments, result }` serialized.

| Construct | Pushed when | `arguments` / `result` stored |
| --- | --- | --- |
| step | success and `rollback_tracked?` | resolved arguments / result (unchanged) |
| compose | success | unchanged |
| map, inline | success (unchanged) | unchanged (resolved args + collected result) |
| **map, fan-out** (new, R-03) | collector success branch, before resuming the parent | `{}` / `Success(nil)`. `MapStep#undo` reads neither field |
| `async_step`, `async_reactor` | never (`rollback_tracked? == false`) | — |

## 5. Map element outcome (R-02, R-04)

Element outcome is derived. It is not stored as a new field.

| Outcome | Source of truth | Rolled back by the map? |
| --- | --- | --- |
| succeeded | element context `status == completed` | **yes**: replay its undo stack, then save the element |
| failed | element context `status == failed` (it already rolled itself back) | no |
| halted | element context `status == halted` | no (`Halt` semantics unchanged) |
| skipped (fail-fast) | results hash slot `{ "_skipped" => true }`. No executed context | no |
| never dispatched (fail-fast) | results hash slot `{ "_skipped" => true }`, written by the dispatcher claim | no |
| context expired | id in the element index, context row missing | reported: `reason: :context_unavailable` |
| live duplicate | the `map_element:<map_id>:<index>` lock is held when rollback runs | reported: `reason: :element_in_flight` |

**Element index**: the existing list `store_map_element_context_id(map_id, context_id, parent_class)`.
Rollback dedupes the ids. The element index number comes from the element context's
`map_metadata[:index]`.

**Settled**: every `0...count` index has a slot in the results hash. The slot is a value, an
`_error`, a `_halt` or a `_skipped`. A fail-fast failure is applied to the parent only once the map
is settled.

**Order**: descending element index.

## 6. Rollback failure entry

These are the existing keys: `step`, `kind` (`:compensate`/`:undo`), `key`, `reason`, `message`.

| Addition | When |
| --- | --- |
| `map_step:` (Symbol) | the entry came from a map element's rollback |
| `element_index:` (Integer, or `nil` for `:context_unavailable`) | same. It is `nil` when the element's row expired, because the index lives only in the row |
| `reason: :context_unavailable` | an element context expired before rollback |
| `reason: :element_in_flight` | the element's liveness lock was held at rollback time |

Entries from an element's own steps keep `step:`, the element step's name.

## 7. Trace entry: discarded compose attempt (R-05)

This entry is appended to the **parent** context's `execution_trace` when `ComposeStep#run` starts a
fresh child because the stored child context is `failed`.

```text
{ type: :compose_attempt_discarded, step: <compose step name>, child_context_id: <old id>,
  rollback_failures: [<entries from the old child>], timestamp: }
```

## 8. Async step record: compensation (R-09)

This adds one field to the existing step result record (`store_step_result`). The unit writes it
in its own job and never writes the parent context.

```text
"compensation" => {
  "status" => "completed" | "failed" | "skipped",   # skipped: compensate returned Skipped / not declared
  "rollback_failures" => [<entries>],
  "completed_at" => iso8601
}
```

The field is present only when the body ran and finally failed. It is absent for successes, halts,
never-started failures and retried attempts that later succeeded.

## 9. Failure attribution (FR-017)

Every failure returned on these paths carries `reactor_name`, `step_name` (when a step was
executing), redacted `inputs` and a reason. `exception_class` is the original cause's class:

- argument resolution
- a raising condition
- an unknown `StandardError`
- a failed compensation (`CompensationError`)
