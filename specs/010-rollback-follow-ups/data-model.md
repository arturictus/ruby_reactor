# Data Model: Rollback and Resume Follow-ups

**Feature**: [spec.md](spec.md) | **Research**: [research.md](research.md)

All records live in Redis through `Storage::RedisAdapter`. `<Class>` is the reactor's storage name
(`RubyReactor.reactor_storage_name`), and `<id>` is the run's context id.

## 1. Run liveness lock (changed holders)

`lock:async:<id>` is the existing re-entrant lock: Lua owner/count hash, TTL `context_lock_ttl`,
auto-extended by its holder.

| Holder | Since | Wait | Taken | Released |
| --- | --- | --- | --- | --- |
| `Executor#resume_execution`, `#resume_rollback` | 004/009 | 0 | after the reactor-level gates' rate-limit check | after the final save (009 R-13) |
| `Reactor#undo` | 009 R-12 | 5s | before undoing; **now also before reloading** (R-09) | after the save |
| **`Executor#execute`** (root, caller process) | **010 R-01** | 0 | after input validation, before the reactor-level lock and semaphore | **after the final save** |
| **`Worker#perform`** | **010 R-02** | 2s, polling | **before the context is read** | in `ensure`, after the executor released its re-entry |
| **`Reactor#continue`** | **010 R-05** | 0 | after the claim, **before the reload** | after the resume returns, or before the hand-off enqueue |

- **Re-entry**: the Worker and `continue` pass their owner to the executor
  (`Executor#context_lock_owner=`). The executor's acquire then raises the count instead of
  contending.
- **Inline job-testing mode**: no holder takes it (unchanged).
- **Reader**: `Sweeper#run_once`, which is unchanged. It now sees caller-process runs as live.

## 2. Interrupt resume claim (new)

| Field | Value |
| --- | --- |
| Key | `reactor:<Class>:context:<id>:resume:<step>` |
| Value | `ContextSerializer.serialize_value(payload)`, as JSON |
| Created | `SET NX EX context_ttl`, by `Reactor#continue` after the payload has validated |
| Read | `MGET` over the reactor's interrupt steps that have no result yet: `Executor#resume_execution` right after the context lock, and `Worker#perform` for a `paused` run |
| Deleted | never; it expires with TTL |

**Lifecycle** of one interrupt:

```text
absent ──continue (valid payload, SET NX wins)──▶ claimed ──lock owner applies──▶ applied
  │                                                  │                              │
  │                     second continue: SET NX loses ─▶ "already resumed"          │
  └──────────────── continue after apply: the result exists ─▶ "already resumed" ◀──┘
```

- **Applied** means `context.set_result(step, payload)` by the execution that owns the lock,
  persisted by that execution's next save.
- An applied claim stays as the dedupe marker until it expires. After that, the step's result in
  `intermediate_results` rejects duplicates.

**Validation rules**:

- A claim is written only for an interrupt step that is ready, has no result and has passed payload
  validation (FR-008, FR-017, FR-020).
- The run must be `paused` or `running`, and not `cancelled`.

## 3. Interrupt attempt counter (moved)

| Field | Value |
| --- | --- |
| Key | `reactor:<Class>:context:<id>:resume_attempts:<step>` |
| Value | an integer, raised by `INCR` once per invalid payload, with `EXPIRE context_ttl` |
| Replaces | `context.private_data[:interrupt_attempts][step]`, no longer written |

At `step_config.max_attempts`, the run fails through `Reactor#undo(failure:)` (R-08, R-09). The
`failure_reason` is unchanged: `message`, `step_name`, `errors`, `payload`, `step_arguments`,
`attempts`, `validation_errors`.

## 4. `context.rollback` on an aborted run (extended)

There is no new context attribute. 009 added `rollback`, and 010 adds keys for the aborted case
(R-10).

| Key | Type | Meaning |
| --- | --- | --- |
| `trigger` | `"failure"` | a step failure was rolling back when the process was interrupted |
| `step` | String | the failing step's name, at this context's level |
| `compensated` | Boolean | whether that step's `compensate` returned. `false` makes manual undo re-run it |
| `arguments` | serialized Hash | the step's `rollback_arguments`. **Its presence marks the aborted record**; 009 hand-off records do not carry it |
| `error` | `{ "class", "message" }`, or a String | the failure that `compensate` receives again |
| `failures` | serialized Array | rollback failures collected before the interruption (009) |

**State transitions** (top level; a composed child or inline element behaves the same at its own
level):

```text
running ──step fails──▶ (compensate running) ──interrupted──▶ aborted + rollback{compensated:false}
                                                                 │
                       Reactor.undo: lock, reload, merge record, undo_all
                                                                 ▼
           compensate re-run (once) ─▶ compensated:true ─▶ undo stack replayed ─▶ cancelled
running ──step fails──▶ compensate returns ──interrupted during undo stack──▶ aborted (no record;
                                                         manual undo replays the remaining stack only)
```

`Web::API` derives `pending_compensation: { step: }` from this record when the status is `aborted`
and `compensated` is false (R-11).

## 5. Map step declaration: `undo_all` (new)

| Field | Where | Value |
| --- | --- | --- |
| `undo_all_block` | map `StepConfig#arguments`, source `Template::Value` | the block given to `undo_all`; absent when not declared |

**Validation rules** (`MapBuilder`, at class definition): a block is required, and the method may be
declared once per map. Either violation raises `Error::ValidationError` naming the map (FR-027).

### Bulk undo inputs and outcome

| Item | Fan-out map | Inline map |
| --- | --- | --- |
| Completed results | forward result slots, in index order, `Success` values only (`Map::ResultEnumerator`) | element contexts with status `completed`, in index order, one deserialized at a time |
| Replayed per element instead | none (no element is `aborted`) | elements with status `aborted` (pass 1, `Map::ElementRollback`) |
| Reported unavailable | indexes with no result slot | element contexts that expired, as in 009 |
| Rollback records or jobs | none | none |

Outcome entries:

- **Execution trace**: `{ type: :undo_all, step: <map step>, count: <completed>, result: <value or error>, timestamp: }`.
- **Rollback failure**, on a raise or a returned `Failure`:
  `{ step: <map step>, kind: :undo_all, reason: :raised | :returned_failure, message: }`. It is
  aggregated into the run's final failure like any rollback failure.

## 6. Worker decision by status (R-06)

| Stored status | Action |
| --- | --- |
| `completed`, `failed`, `cancelled`, `skipped`, `aborted`, `halted` | return (release the lock) |
| `paused` | resume if any interrupt without a result has a claim; otherwise return |
| `rolling_back` | `resume_rollback` |
| `running` | `resume_execution` (applies claims first) |

## 7. Snooze limit (R-07)

| Condition | Limited by `lock_snooze_max_attempts`? |
| --- | --- |
| Reactor-level lock, semaphore or rate limit before admission (`!context.admitted?`) | yes (unchanged): escalate to `failed` |
| Reactor-level lock or semaphore once admitted | **no**: one `ruby_reactor.resume.waiting` warning at the limit, then keep snoozing |
| `ContextLockContention`, `OrderedLock::WaitError`, `ExecutionParked` | no (unchanged) |
