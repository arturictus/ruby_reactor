# Phase 1 Data Model: Step-Scoped Coordination

**Feature**: `specs/003-step-lock-declarations/` | **Date**: 2026-09-10

Definition-time state lives on Ruby classes. Runtime state lives in Redis (the holds
themselves, unchanged key spaces) and in `context.private_data` (per-execution bookkeeping,
which already round-trips through `ContextSerializer`).

## StepCoordinationDeclaration

What a unit of work declares about when it may run. One per primitive per step; a step may
declare several.

| Field | Type | Notes |
|---|---|---|
| `primitive` | `:lock` \| `:semaphore` \| `:rate_limit` \| `:period` \| `:ordered_lock` | |
| `key_proc` | Proc | Receives the step's **resolved arguments**, returns the key. Where the reactor form receives reactor inputs. |
| `ttl` | Integer | `:lock`, `:ordered_lock`. Default as today. |
| `wait` | Integer | `:lock`, `:semaphore`. Tolerance before contention handling. |
| `auto_extend` | Boolean | `:lock`. Keeps the hold alive while the step's work runs. |
| `limit` | Integer | `:semaphore` — concurrent holders per key. |
| `limits` | Hash | `:rate_limit` — window → ceiling, or a registered name. |
| `every` | Symbol \| Integer | `:period` — bucket size. |
| `poison_pill_timeout`, `strict` | Integer, Boolean | `:ordered_lock`. |

**Validation rules**:

- Declaring any primitive on an interrupt step raises at declaration time (research D6).
- The existing per-macro argument validation is unchanged — e.g. `with_rate_limit(:name)`
  still refuses to also take `limit:`/`period:`/a block; `with_period` still validates `every:`
  eagerly at class load.
- A key proc returning nil or empty fails the step before its work runs (FR-007).

**Ownership**: a step class, or an inline step's `StepConfig`. Propagates to subclasses via
the existing `inherited` hook; a subclass redeclaring a primitive replaces the parent's.

**Introspection** (FR-006): `declares_coordination?`, `coordination_declarations`, and the
existing per-primitive readers (`lock_config`, `semaphore_config`, …) available on the step.

## Hold

The runtime fact that one execution holds one key. Redis-side representation is unchanged —
this is the model of what already exists, now also created by steps.

| Field | Source | Notes |
|---|---|---|
| `key` | key proc output, namespaced per primitive | |
| `owner` | root context id | The basis of re-entrancy: every reactor and step in one execution tree shares it. A direct step invocation uses a per-call UUID instead. |
| `owning_step` | step name | New. Nil for a reactor-level hold. |
| `nesting_count` | adapter-maintained | Increments on re-acquire by the same owner; the key frees at zero. |
| `acquired_at`, `ttl` | as today | Refreshed by the auto-extend thread while the step's work runs. |

**Lifecycle**: `acquired` → (`extended`…) → `released`, or `expired` if the holder dies.
Release is in `ensure` around the step body, in reverse acquisition order.

## HeldKeyRegistry

`root.private_data[:held_lock_keys]` — the set of keys this execution currently holds.
Unchanged structure; step holds push and pop the same way reactor holds do.

Read by the dispatch-time deadlock guard: handing off work that declares a key present in the
registry is refused before dispatch (FR-022). Extended in this feature to consult a dispatched
**step class's** declarations, not only a child reactor's.

## ContentionState

Per-execution bookkeeping for the park-and-retry path, in `context.private_data`.

| Field | Type | Notes |
|---|---|---|
| `attempts_by_step` | Hash{step → Integer} | Counted separately from failure retries, so a busy key cannot exhaust the budget meant for genuine failures. |
| `ceiling` | Integer | Configurable. Exceeding it converts the park into a contention failure (FR-017). |
| `next_attempt_at` | Time | Set from the primitive's own hint (`retry_after_seconds` for rate limits) or the configured contention backoff. |

**Transitions**:

```text
reached step ──cannot acquire──> in a worker?
                                  │
                      yes ────────┴──────── no
                       │                     │
              attempts < ceiling?      waited `wait` already
                 │         │                 │
               yes        no                 │
                 │         │                 │
        park + requeue   contention      contention
        (RetryQueued)     failure         failure
                 │
          redelivered ──> retry acquisition
```

A parked execution has run no part of the contended step and compensated nothing (FR-015).

## StepOrderedLockState

Per-step sequencing state, in `context.private_data`, keyed by step name. Mirrors the
reactor-level `private_data[:ordered_lock]` stash.

| Field | Notes |
|---|---|
| `key`, `nonce`, `epoch` | Assigned when the execution first reaches the step; reused across contention redeliveries. |
| `poison_pill_timeout`, `ttl`, `strict` | From the declaration. |

**Caveat carried from research D8**: the nonce is assigned on arrival at the step, not at
enqueue, so the guarantee is arrival-ordered rather than enqueue-ordered.

## CoordinationOutcome

What the executor produces at a coordinated step boundary.

| Outcome | When | Result |
|---|---|---|
| Proceed | All declared primitives taken | Step body runs, holds released after |
| Skip | Dedup window already marked for this bucket and key | `Skipped` for the step; workflow continues (FR-003) |
| Skip (chain) | Strict ordering and an earlier position failed | `Skipped` for the step (FR-004) |
| Park | Contention, in a worker, under the ceiling | `RetryQueuedResult`; execution resumes at this step later |
| Fail | Contention synchronously, or over the ceiling, or key computation failed | Step failure; rollback proceeds as for any step failure |
| Refuse | Hand-off would deadlock on a held key | Failure at dispatch, naming key, holder, and remedies (FR-022) |

## Rollback interaction

| Primitive | Re-taken for compensate/undo? |
|---|---|
| `:lock` | ✅ same key, same values (FR-024) |
| `:semaphore` | ✅ |
| `:rate_limit` | ❌ a forward-work quota must not suppress cleanup (FR-025) |
| `:period` | ❌ same reason |
| `:ordered_lock` | ❌ sequencing governs forward work |

Compensation that cannot acquire within its wait is reported, never silently skipped
(FR-026), and never parks — the execution is already mid-failure.
