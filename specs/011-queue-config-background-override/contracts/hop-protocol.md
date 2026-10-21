# Contract: Queue Hop Protocol

**Feature**: [../spec.md](../spec.md) | **Research**: [../research.md](../research.md) R-04–R-08

How a run moves between queues without weakening a guarantee (FR-009–FR-019). It reuses two
existing protocols: the **park** (005, a forward hop) and the **rollback hand-off** (009, a rollback
hop).

## 1. Invariants

| Id | Invariant | Held by |
| --- | --- | --- |
| H-1 | **Persist before enqueue.** The root context is saved, and the dispatch record written, before the next job exists | Root executor `ensure` save (park), `record_rollback_handoff` save (rollback), then `Queues.enqueue_run` writes the record, then the router |
| H-2 | **One job advances a run.** The job that enqueues the hop still holds `async:<id>`. The new job takes the lock before loading (010 R-02) | `Worker#perform` lock → load → `perform_locked` → hop → `ensure` release |
| H-3 | **Holds survive the hop**, forward and during rollback. Reactor-level `with_lock` and `with_semaphore`, at every compose level, stay checked out and are re-adopted on arrival. A lock's TTL is extended to `context_ttl` for the wait. A run that ends without resuming them (rollback finished, undo, cancel) releases what is still parked in its tree | `park_held_primitives!` + `Lock#detach(lease:)` (also in `record_rollback_handoff` for a queue hop); `consume_parked_primitives!` + `reattach` (also in `resume_rollback`); `Executor.release_parked_holds` |
| H-4 | **No double charge.** The rate limit and the period gate are first-run only. The ordered lock never meets a hop | `rate_limit_charged` marker; `first_execution?`; R-09.2 rejection |
| H-5 | **No completed step re-runs.** A hop happens between nodes, after the last step's checkpoint. The resume starts at the pinned node | Per-step `checkpoint!`; `current_step` pinned; `GraphManager#mark_completed_steps_from_context` |
| H-6 | **No undo or compensate runs twice.** An undo entry leaves the stack only after its undo returned. A rollback hop is raised before the entry's undo and saves the stack | `rollback_completed_steps` order (008 R-16); 009 `record_rollback_handoff` |
| H-7 | **Every job knows its real queue.** It is the job argument, not the record, so a duplicate on the wrong queue still hops instead of running a step there | R-03 job argument → `current_queue` |
| H-8 | **Hops happen only in jobs** (FR-006) | `Queues.current(ctx)` is nil in the calling process |
| H-9 | **A composite in progress does not hop by itself.** The units inside it decide | Forward: a `compose` with a child context. Rollback: a `compose` whose child has a `rollback` state |
| H-10 | **No hop inside a map element; no hop under an ordered lock** | `validate_definition!` (R-09) |

## 2. Sequences

### P-1 Forward hop and hop back (US2-AS1)

```text
Caller:   MyReactor.run → :first (caller) → background after: :first
          → enqueue_run(queue: node_queue(:second) = my_specific_queue)       # 1 hand-off job
Job A1 (my_specific_queue): lock, load, record.since cleared, current_queue = my_specific_queue
          :second ✓ checkpoint
          :bank_deposit  node_queue = stripe ≠ current → pin, trace queue_hop, before_async_enqueue
          raise QueueHop(stripe) → park holds (lock leased) → save → Worker: enqueue_run(stripe)
Job S1 (stripe): lock, load, re-adopt holds, run pinned :bank_deposit
          ComposeStep → child steps inherit stripe → all run here ✓
          :third  node_queue = my_specific_queue ≠ current → QueueHop(my_specific_queue)
Job A2 (my_specific_queue): :third ✓ → completed
Jobs: 3 = 1 hand-off + 2 queue changes (SC-003)
```

### P-2 A unit inside a composed child on another queue

```text
S1 (stripe): :bank_deposit is in progress (child context exists) → no hop at the compose (H-9)
   child :one ✓, child :two (step class queue :ledger) → QueueHop(ledger)
   the child executor parks its holds, the root parks its holds, the root saves
L1 (ledger): root → :bank_deposit (in progress, no hop) → child resumes → :two ✓
   child :three (inherits stripe) → QueueHop(stripe) … and back out to the parent's queue after
```

### P-3 Rollback hops (US2-AS6)

```text
A2 (my_specific_queue): :third fails
   handle_step_failure → compensate :third HERE (no check)
   rollback_completed_steps: top = :bank_deposit, node_queue stripe ≠ current
   → trace queue_hop(rollback), raise RollbackHandedOff(queue: stripe), entry NOT popped
   → record_rollback_handoff (trigger failure, compensated true, failures) → status rolling_back
   → save → enqueue_run(stripe)
S2 (stripe): resume_rollback → finish_rollback → undo :bank_deposit (child undo_all on stripe) → pop
   top = :second, node_queue my_specific_queue ≠ stripe → RollbackHandedOff(queue) → save → enqueue
A3 (my_specific_queue): undo :second, :first → handed_off_failure → failed
```

A rollback hop raised inside a child's `undo_all` behaves like 009's: the child saves its failures on
its own `rollback`, the compose entry stays on the root's stack, and when the run resumes, H-9 stops
the root from hopping back for that compose entry.

### P-4 Manual undo hand-off (US2-AS11, FR-018)

```text
Admin: MyReactor.undo(id)
   lock async:<id> (wait 5s) → reload → guard rolling_back
   Queues.declares_any?(MyReactor) → true
   rollback = {trigger: "undo", compensated: true, failures: []} (+ failure_reason)
   status = rolling_back → save → enqueue_run(node_queue(undo_stack.last)) → release → return
Worker(s): resume_rollback → finish_undo → rollback_completed_steps with hops → cancelled
Meanwhile: undo / cancel / continue → ValidationError (rolling_back guards, unchanged)
```

### P-5 Hand-off target (R-06)

| Point | First job's queue |
| --- | --- |
| `before: :x` | `node_queue(:x)` |
| `after: :x` | `node_queue` of the first ready node after `:x` |
| `all: true` | The root reactor's effective queue |
| Interrupt resume (`background`, or the run is busy) | The record's queue, else the reactor's effective queue |

## 3. Crash and duplicate windows (SC-004)

| Window | What remains | Recovery | Result |
| --- | --- | --- | --- |
| Forward: after the save, before `enqueue_run` writes the record | Context saved with `current_step` pinned. The record shows the previous queue. Lock lapses | The sweeper re-enqueues to the record's (old) queue. That job hops (H-7) | Completes once |
| Forward: after the record, before the router enqueues | Record `{target, since}` and no job. Lock lapses | The sweeper re-enqueues to the target | Completes once |
| Forward: after the enqueue, before the old job releases | New job queued. The old job may be redelivered | The redelivered old job takes the lock (or waits, then snoozes), loads the newer state, finds the node is not on its queue, sees the record pending for that queue, and exits (dedupe) | Completes once, no step runs twice |
| Duplicate delivery of the hop job | Two jobs on the target queue | Serialized by the lock. The second loads the later state and continues, hops or dedupes, or exits if the run is terminal | Completes once |
| Rollback: the same three windows | Context `rolling_back` with the stack saved | The sweeper re-enqueues `rolling_back` runs (009 S-5) to the record's queue. `resume_rollback` continues from the first entry not popped | Ends `failed`/`cancelled`, each undo once |
| Enqueue raises (backend down) | Context saved, record maybe written | The job raises and the backend retries it. Its redelivery loads, and hops again or dedupes. The sweeper is the backstop | No step runs in the wrong job |

## 4. Costs

- **Per hop**: the root save (already done for a park), one `HSET` (the record), one enqueue, and
  one `PEXPIRE` per reactor `with_lock` held.
- **Per pickup**: one `HGET` and, when it matches, one `HSET`.
- **Per run**: one extra job for each queue change, forward and during rollback. This is the cost
  the spec accepts.
