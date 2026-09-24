# Data Model: Step Coordination Review Remediation

**Feature**: [spec.md](./spec.md) | **Research**: [research.md](./research.md)

This feature adds no Redis key spaces. Every new piece of state lives on a structure that
already exists: the step declaration's config hash, `Context#private_data`, the Step Result
Record, or `RubyReactor::Failure`.

## Rollback Wait (FR-001–FR-003)

This is a field on the step's coordination config. `Dsl::Lockable` is shared, so it sits on the
same hash for reactors and steps, but only rollback reads it.

| Config | Field | Type | Default | Notes |
|---|---|---|---|---|
| `lock_config` | `rollback_wait` | Numeric seconds, or `nil` | `nil`, meaning the lock's `ttl` (60 by default) | Used by `StepCoordination#rollback_with_lock` in place of `wait`. Ignored at reactor level, because reactor locks are not re-taken for rollback. |
| `semaphore_config` | `rollback_wait` | Numeric seconds, or `nil` | `nil`, meaning `StepCoordination::DEFAULT_ROLLBACK_WAIT` (60) | A semaphore has no hold expiry (research D-F1). |

**Validation**: a value that is not `nil` must be numeric and `>= 0`. `0` means the rollback
does not wait. It is legal but defeats D-F1, so it is documented as such.

## Rollback Failure Entry (FR-004, FR-005)

One element of `RubyReactor::Failure#rollback_failures`.

| Field | Type | Values |
|---|---|---|
| `step` | Symbol | The step whose undo or compensation did not complete. For a composed child, it is the child's step (entries are flattened, research R-08). |
| `kind` | Symbol | `:undo` for a completed step being rolled back. `:compensate` for the failing step's own compensation. |
| `key` | String or `nil` | The coordination key when `reason == :coordination_unavailable`, otherwise `nil` |
| `reason` | Symbol | `:coordination_unavailable`, `:returned_failure` or `:raised` |
| `message` | String | A readable cause, such as "could not re-acquire lock 'acct:1' for rollback of :charge within 60s" or the exception message |

**Ordering**: rollback order. Child entries come before the parent's own entries.

**Serialization**: `Failure#to_h[:rollback_failures]`. It is round-tripped through
`extract_attributes_from_hash`, so it survives the async failure blob and
`ContextSerializer`.

**Lifecycle**:

1. `CompensationManager#@rollback_failures` fills during `rollback_completed_steps` and
   `compensate_step`.
2. `ResultHandler#handle_execution_error` copies the list onto the final Failure. This is the
   one choke point.
3. The list is never cleared after that. One executor produces one final Failure.

## Execution Admission (FR-007, FR-008)

| Location | Key | Type | Set when | Read by |
|---|---|---|---|---|
| `Context#private_data` of the executor's **own** context (root or composed child) | `:admitted` | `true` | The reactor-level gates passed: rate limit, period pre-check and post-lock period re-check. This is in `execute`, and in `resume_execution` on a first run. | `Executor#first_execution?`, `OrderedLockSupport#fresh_ordered_lock_start?`, `ComposeStep#execute_child_reactor` (resume versus execute) |
| same | `:rate_limit_charged` | `true` | `Executor#check_rate_limit` charged the reactor-level rate limit (research R-14). | `Executor#check_rate_limit`, which skips the charge. A lock or semaphore contended right after the charge snoozes the job before `admitted` is set, and the redelivery is still a first run. |
| same, composed child only | `:admission_parks` | Integer | The child parked on its own reactor-level contention inside a worker (research R-16). | `Executor#composed_contention_park`: past `lock_snooze_max_attempts` the contention error goes through as the `compose` step's failure. |

**Derived predicate**:
`fresh? = !admitted && current_step.nil? && intermediate_results.empty?`. The last two
conditions keep a legacy context, saved before this field existed, behaving as it does today.

**Invariant**: once `admitted` is true it is never unset. It survives parks, retries, pauses and
redeliveries because it is serialized with `private_data`. `current_step` becomes only the
resume cursor.

## Park Signal (FR-006, FR-009)

These are exceptions. They are never persisted.

```text
Error::Base
└── Error::ExecutionParked          # new; "this execution parks, re-raise to the worker"
    ├── Error::AsyncResultPending   # existing; superclass changed from Base
    ├── Error::StepContentionPark   # new; carries the Contended
    └── Error::ReactorContentionPark # new (R-16); a composed child's own reactor-level contention
```

| Class | Attributes | Raised by | Final handler |
|---|---|---|---|
| `AsyncResultPending` | `channel` (existing) | `Template::Result` inside a worker | `Worker` snooze, uncapped (bounded by `async_park_timeout` at the wait site) |
| `StepContentionPark` | `contended`, plus `original` and `retry_after_seconds` (delegated) | `StepExecutor#handle_contention` when `inline_async_execution` is set and the contention ceiling has not been reached | `Worker` snooze, uncapped (the ceiling is enforced at the raise site). `Map::ElementExecutor` requeues through `perform_map_element_in`. |
| `ReactorContentionPark` | `original` (the `Lock`/`Semaphore::AcquisitionError` or `RateLimit::ExceededError`), `retry_after_seconds` (delegated) | `Executor#execute`/`#resume_execution` of a composed child in a worker, not under an inline map element, below its `admission_parks` ceiling | Same as `StepContentionPark`: uncapped at the `Worker` and `Map::ElementExecutor`, bounded at the raise site. |

**Propagation contract**: every rescue between the raise site and the final handler either
re-raises a park signal untouched or parks its own holds and then re-raises. The rescue-site
table in research R-01 is the full list.

## Parked Primitives (existing, now per level)

`private_data[:parked_primitives] = { lock: true, semaphore_token: "…" }` was only ever
written on the root context. It is now written on **each** executor's own context that holds
reactor-level coordination at park time (D-A2). A child's copy is saved inside the root blob
through `composed_contexts`. It is consumed once, on that executor's next `resume_execution`
(`consume_parked_primitives!`, unchanged).

## Ordering Position Outcome (FR-010–FR-015)

**Gate classification** (`OrderedLockSupport.gate(info, fresh:)`, research R-06), shared by
both levels:

| `OrderedLock#check!` result | Outcome | Reactor level | Step level |
|---|---|---|---|
| `:go` (includes `poison_advance`) | `:go` | run | run |
| raises `WaitError` | wait | worker: snooze. sync: raise to caller (unchanged) | worker: park (position kept). sync: `advance(failed: false)`, then contention Failure (D-F3) |
| `:skip_chain_failed` with `fresh` | `:skip_chain` | `Halt(:ordered_lock_chain_failed)` | `Skipped(:ordered_lock_chain_failed)` plus `advance(failed: false)` |
| `:skip_chain_failed` without `fresh` | `:go` | run (an in-flight run completes) | not reachable: the step level always passes `fresh: true` |
| `:stale_batch` | `:stale` | `Halt(:ordered_lock_stale_batch)` | `Skipped(:ordered_lock_stale_batch)`, no advance, stash deleted (**F7**) |
| `:drained_go` | `:drained` | run, or `Halt(:ordered_lock_drained_replay)` if the stored status is terminal | run |
| anything else | raises | — | — |

**Step-level position lifecycle** (research R-07). The outcome is decided once, and the work
happens in `ensure`:

| Outcome | Heartbeat | Advance | Stash |
|---|---|---|---|
| `:succeeded` | stopped | `failed: false` | deleted |
| `:failed` (at head) | stopped | `failed: true` | deleted |
| `:retry_pending` | stopped | none | kept |
| `:parked` (`Contended` in a worker, or `ExecutionParked`) | stopped | none | kept |
| `:abandoned` (an exit that is not a `StandardError`) | stopped (**F8**) | none; the poison pill releases it | kept |

## Step Result Record, `async_step` (FR-017–FR-019)

Fields added to the existing record hash (`storage.store_step_result`):

| Field | Type | Written by | Read by | Cleared |
|---|---|---|---|---|
| `ordered_lock` | Hash `{key, nonce, epoch, poison_pill_timeout, ttl, strict}` or absent | `StepWorker#mark_record_parked` (from the step's stash) | `StepWorker#load_step_context`, which copies it into the step context's `private_data[:step_ordered_locks][step]` | `complete` writes a fresh record |
| `waiting` | Hash `{step, primitive, key, attempts}` or absent | `StepWorker#mark_record_parked` | `Web::CoordinationSerializer` for `async_dispatch == :step` steps | `complete` writes a fresh record |
| `started_at` | ISO 8601 string (µs), absent until the body is reached | `StepWorker#mark_record_parked` and `#complete` | `Web::API.async_step_runs` (places the rebuilt `:run` entry) | never; a later delivery overwrites it |
| `arguments` | the step's resolved arguments, contract-redacted, `ContextSerializer`-serialized | same | `Web::API.with_async_step_runs` (the `:run` entry, and the coordination panel's key) | never |
| `attempts` | Integer, body attempts in the delivery that wrote the record | same | `Web::API.with_async_step_attempts` | never |

Existing fields `parked_until` and `contention_attempts` are unchanged.

**Invariant**: the step's worker is the record's only writer while the unit is not terminal.
The parent's root blob is never written by the unit — not on a park, not on completion, not on
failure (R-18). The parent holds only the `:async_step_ref` link written at dispatch.

## Middleware Event: `:snooze_step` (research R-04)

| Event | Args | Emitted when |
|---|---|---|
| `:snooze_step` | `step_name, error (ExecutionParked), context` | A park signal passes `StepExecutor#execute_step`. It takes the place of `:failed_step` and `:complete_step` for that attempt. |

`OpenTelemetry#on_snooze_step` finishes the step span with `step.status = "parked"` and status
OK.
