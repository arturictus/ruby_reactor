# Reactor Durability: Findings & Improvement Plan

## Context

We are revisiting how async reactors survive process restarts and crashes. The
goal is to be able to make an honest, defensible claim about durability:

> If a Sidekiq process is shut down or killed while a reactor is running, the
> reactor resumes and finishes correctly.

This document records how the system behaves **today**, why the current claim is
only conditionally true, and the concrete changes we will make to strengthen it.

---

## Current behaviour (as of this investigation)

### Execution model

- The **first** async step hands off to a Sidekiq worker. The worker sets
  `inline_async_execution = true`, so every *subsequent* async step runs
  **inline in the same worker job** rather than being re-queued.
  - `lib/ruby_reactor/executor/step_executor.rb:72` (the inline decision)
  - `lib/ruby_reactor/sidekiq_workers/worker.rb:45` (the flag)
- Result: one Sidekiq job typically executes a **span of multiple steps**, not a
  single step.

### Where state lives

- **The durable checkpoint is the Sidekiq job payload**, written at each async
  handoff. `handle_async_step` re-serializes the live context (including all
  `intermediate_results`) into a brand-new job before returning.
  - `lib/ruby_reactor/executor/step_executor.rb:206-212`
- The worker rehydrates the context **purely from the job payload argument**, not
  from storage.
  - `lib/ruby_reactor/sidekiq_workers/worker.rb:22`
- Between steps within one job, results live **only in memory** until the
  `ensure` block runs.
  - `lib/ruby_reactor/executor.rb:221`

### The storage adapter is NOT load-bearing today

- `save_context` is **write-only** for the purposes of resume — it powers
  external observability (`Reactor.find`, the web dashboard) and is never read
  back to drive execution.
  - `lib/ruby_reactor/executor.rb:242-249`
- Every caller of `retrieve_context` is external/query or composition-related;
  none is in the resume/retry path. The single exception is the ordered-lock
  short-circuit, which reads stored *status* only to detect terminal
  redeliveries and suppress a re-save — it does not reload state for execution.
  - `lib/ruby_reactor/executor/ordered_lock_support.rb:184`

### Two payloads — do not confuse them

| Path                                  | Payload                    | Freshness                            |
| ------------------------------------- | -------------------------- | ------------------------------------ |
| Async step to next (`perform_async`)  | live context re-serialized | Fresh - has all completed results    |
| Sidekiq retry of a crashed job        | the same original args     | Stale - state as of job start        |

---

## What this means for durability today

1. **Resume granularity is the async-step boundary, not the last finished step.**
   A crash mid-job causes a retry that replays from the job-start payload, i.e.
   it **re-runs every step since the last async boundary**. In-memory results for
   inline steps completed during that job are lost (never persisted, never read
   back).

2. **No step-level idempotency guard exists.** Re-running a step with side
   effects (charge, email, insert) duplicates them unless the step is itself
   idempotent.

3. **Sidekiq OSS can lose the job entirely on a hard kill.** OSS fetch removes
   the job from Redis the moment a worker claims it; a SIGKILL/OOM/crash mid-job
   means the job is **never redelivered** (requeue-on-crash needs Sidekiq
   Pro/Enterprise `super_fetch`). Graceful SIGTERM within the shutdown timeout
   does push unfinished work back.

### Honest claim today

> The reactor resumes from the last **async-step boundary**, *if* the job
> survives (graceful shutdown or super_fetch) **and** the steps between
> boundaries are idempotent.

Not yet a blanket durability guarantee.

---

## Proposed change — make storage load-bearing

We can dramatically improve durability **without changing the async-boundary
model** by promoting the storage adapter from an audit log to the source of
truth.

1. **On async handoff:** persist the context to storage and enqueue the job with
   **only the reactor's unique id** (not the full serialized payload).
2. **On worker start:** rehydrate the context from storage by that id.
3. **Persist the updated context at the end of every step.**

### Why this helps

- **#3 (save per step)** turns every completed step into a durable checkpoint.
  Crash → retry resumes from the **last completed+persisted step**, not from
  job-start. The re-run blast radius shrinks from "whole inline span" to "the one
  in-flight step." This is the win we wanted from per-step requeue, gotten
  without touching async boundaries.
- **#1 + #2 (id-only payload + rehydrate)** eliminate the stale-payload bug. A
  retry rehydrates the **fresh** context from storage, automatically sees steps
  that completed before the crash, and skips them. The fresh/stale payload
  distinction disappears.

### New claim this enables

> The reactor resumes from the last **completed and persisted** step. Only the
> single step in flight at crash time may re-run.

Much narrower, and defensible — subject to the remaining holes below.

---

## Remaining holes (must address to fully claim durability)

1. **Lost job (delivery guarantee).** Storage will hold the context, but if the
   job is dropped on a hard kill, nothing re-triggers it — the context is
   orphaned. **Fix:** either `super_fetch`, or a **sweeper** that scans storage
   for non-terminal contexts past a heartbeat and re-enqueues them by id. The
   id-only payload makes the sweeper trivial. *Biggest remaining gap.*

2. **In-flight step idempotency (irreducible).** There is always a window between
   a step's side effect and its `save_context`. A crash there re-runs that one
   step. At-least-once is unavoidable; we have only narrowed it to a single step.
   Order operations as `side-effect → record result → save context`, and that
   step must be idempotent.

3. **Concurrent delivery race.** Storage becomes mutable shared state keyed by
   id. Double-delivery (a retry firing while the original is still alive) means
   two workers rehydrate the same id and both write → last-writer clobbers /
   possible double execution. **Fix:** a **per-context lock** around
   rehydrate → run → save. The existing nonce/ordered-lock primitives (PR #26)
   may be reusable.

4. **TTL management.** Redis storage currently has a 24h TTL
   (`lib/ruby_reactor/storage/redis_adapter.rb:20`). With storage load-bearing, a
   snoozed/long-running reactor past TTL becomes unrecoverable and its id-only
   job is orphaned. **Fix:** refresh/extend TTL on each save; tie it to the max
   retry/snooze window.

5. **Save cost.** An extra Redis write plus full re-serialize per step. Usually
   fine; watch large contexts and hot paths (map fan-out).

---

## Per-context lock: primitive verification

We checked whether the existing lock primitives can back the per-context
concurrency guard (hole #3 above). **Conclusion: `RubyReactor::Lock` is reusable
as-is — no new primitive required**, but the owner model must be used carefully.

### What's available

- **`RubyReactor::Lock`** (`lib/ruby_reactor/lock.rb`) — locks on an **arbitrary
  string key** (`lock:<key>`), with owner-proven release via Lua
  (`hget key 'owner' == owner`), configurable TTL, and a background **auto-extend**
  thread that re-stamps every `ttl/3`s. Exposes `acquire` (polls until `wait`
  timeout, raises `AcquisitionError`), `release`, and `synchronize`. Backed by
  adapter primitives `lock_acquire` / `lock_release` / `lock_extend`
  (`lib/ruby_reactor/storage/redis_locking.rb`). This is the right fit.
- **Semaphore(limit: 1)** — works as a mutex but has **no TTL / no auto-extend**,
  so a crashed holder never frees it. Rejected.
- **OrderedLock / nonce lock** (PR #26) — designed for **inter-job FIFO ordering
  on a user key**, not per-context mutual exclusion. It already wraps the run via
  `enter_ordered_lock_scope` / `leave_ordered_lock_scope`
  (`lib/ruby_reactor/executor/ordered_lock_support.rb`), but reusing it as a
  generic context mutex would sacrifice its ordering semantics. Not the tool for
  this. (Its epoch-fencing + poison-pill timeout are good prior art, though.)

### Critical caveat — owner must be per-execution, NOT the context_id

`Lock` is **reentrant for the same owner** (a Redis hash `count` that the same
owner increments). The obvious choice `owner: context_id` is therefore **wrong**
for this guard: a duplicate delivery of the *same* context shares the same owner,
so both workers would re-enter the lock and run concurrently — exactly the race
we are trying to prevent.

- **Key** = the resource → `"async:#{context_id}"` (so all deliveries of one
  reactor contend on the same lock).
- **Owner** = unique per worker execution → the Sidekiq `job_id` or a
  `SecureRandom` nonce (so a second concurrent delivery is **blocked**, and only
  the holder can release).

**Verified safe for nesting.** Composed sub-reactors and map elements each get
their **own** `context_id` (fresh `SecureRandom.uuid` at `Context.new`); they
share only `parent_context_id` / `root_context`, never the `context_id` itself
(`lib/ruby_reactor/step/compose_step.rb:77`,
`lib/ruby_reactor/map/element_executor.rb:76`). So a lock keyed by `context_id`
gives every execution unit a **distinct key** — parallel map siblings and
parent/child reactors do **not** contend. The only jobs that ever share a
`context_id` are **duplicate deliveries of the same execution** — exactly what we
want the lock to serialize. (This is also why the owner must be per-execution:
those duplicates share the context_id, so `owner: context_id` would re-enter and
defeat the guard.)

Note: the existing *user* lock deliberately uses `owner: root_context.context_id`
for cross-nesting re-entrancy (`lib/ruby_reactor/executor.rb:348`). Our guard is a
separate lock (`async:` prefix vs. the user key) with different owner semantics —
no conflict.

### Smallest reuse path

In `resume_execution` (`lib/ruby_reactor/executor.rb`), acquire after
`enter_ordered_lock_scope` and before the user lock/semaphore (~line 164-181),
release in the existing `ensure` block (~line 219) alongside `release_locks`:

```ruby
@context_lock = RubyReactor::Lock.new(
  "async:#{@context.context_id}",
  owner: @job_id || SecureRandom.uuid,  # per-execution, NOT context_id
  ttl: <config>, auto_extend: true
)
@context_lock.acquire   # raises AcquisitionError if another delivery holds it
# ... ensure: @context_lock&.release
```

On `AcquisitionError`, treat it like the existing lock-contention path → snooze
and let the active holder finish (a concurrent duplicate, not a real failure).

---

## Risk minimization

The investigations let us collapse several caveats into fewer mechanisms. How
each hole is reduced to an acceptable, well-understood residual:

### One lock, two holes (concurrency guard + liveness)

The per-context lock we need for hole #3 (concurrent delivery) **is also** the
liveness signal for hole #1 (lost job). While a worker runs, the lock
auto-extends every `ttl/3`. Therefore:

- Lock present  → a worker is alive on this context → sweeper leaves it alone.
- Lock absent + stored `status == "running"` → worker died/lost → sweeper
  re-enqueues by id.

No separate heartbeat field or thread is needed; the lock TTL is the heartbeat.
The sweeper is then just: `scan_reactors` → keep non-terminal → drop any with a
live lock → re-enqueue the rest. Cheap, and the id-only payload makes
re-enqueue trivial.

### Residual risks and how we shrink them

| Risk | Before | After mitigation | Residual |
| ---- | ------ | ---------------- | -------- |
| Re-run blast radius on crash | whole inline span | save-per-step → resume at last persisted step | one in-flight step |
| Stale retry payload | resumes from job-start | id-only payload + rehydrate from storage | none (always fresh) |
| Lost job (hard kill) | stalls forever | sweeper re-enqueues by id, using lock as liveness | bounded by sweeper interval |
| Concurrent double-delivery | double execution | per-context lock, per-execution owner | none (one runs, other snoozes) |
| In-flight step idempotency | any re-run duplicates | narrowed to one step; order side-effect → record → save | irreducible; step must be idempotent |
| Context TTL expiry | 24h fixed | refresh TTL on each save; align to max retry/snooze window | reactors idle > window (rare; documentable) |
| Schema bump strands in-flight | permanent failure | version-tolerant deserialize / drain before bump | needs a deserialize-compat policy |

### The two residuals worth an explicit decision

1. **In-flight step idempotency is irreducible.** At-least-once delivery means the
   one step executing at crash time may re-run. We cannot remove this; we can only
   (a) narrow it to a single step (done, via save-per-step) and (b) document that
   side-effecting steps must be idempotent. Optionally add a per-step idempotency
   key (record "step N committed" before the side effect's external call) for the
   highest-risk steps — but that is opt-in, not a global requirement.

2. **Schema-version strictness.** Today a version mismatch is a permanent failure.
   Once storage is load-bearing and contexts live longer, this becomes a real
   operational hazard on deploy. Mitigation options: (a) make deserialize
   version-tolerant (accept N and N-1, migrate forward), or (b) a deploy
   discipline that drains in-flight reactors before bumping `SCHEMA_VERSION`.
   Recommend (a) — back-compat deserialize — as it removes the hazard structurally.

### Sequencing that minimizes risk during rollout

Land the **per-context lock first** and independently: it is safe on its own
(snooze on contention), it is the prerequisite for safe shared storage, and it
doubles as the liveness primitive the sweeper later relies on. Only then flip
storage to load-bearing (id-only payload + rehydrate + save-per-step), then add
the sweeper, then TTL refresh. Each step is independently shippable and reversible.

---

## Plan of work (ordered)

1. **Per-context lock** — prerequisite for safe shared mutable storage.
   Reuse `RubyReactor::Lock` keyed by `context_id` with a **per-execution owner**
   (job_id / random nonce, not the context_id — see verification above); wrap
   rehydrate → run → save; snooze on `AcquisitionError`.
2. **Core change** — save-per-step + rehydrate-by-id + id-only job payload.
3. **Sweeper** — `scan_reactors` for non-terminal contexts, skip any with a live
   `async:<context_id>` lock, re-enqueue the rest by id (lock = liveness signal).
4. **TTL management** — refresh storage TTL on each save, align with max
   retry/snooze window so load-bearing contexts never expire mid-flight.
5. **Schema back-compat** — make `ContextSerializer` deserialize tolerate the
   previous `SCHEMA_VERSION` so a deploy can't strand longer-lived stored
   contexts (replaces today's permanent `SchemaVersionError`).

### Out of scope (for now)

- Changing the async-boundary model (per-step requeue of inline async steps).
  The plan above achieves the durability win without it.

---

## Open questions — resolved

- **Reusable lock primitive?** Yes — `RubyReactor::Lock` keyed by `context_id`
  with a per-execution owner. (Not the ordered-lock, not `owner: context_id`.)
  See "Per-context lock".
- **Do nested/composed reactors break a per-context lock?** No. They get distinct
  `context_id`s, so they get distinct lock keys and never contend. Only duplicate
  deliveries of one execution share a `context_id`. See "Per-context lock —
  verified safe for nesting".
- **What liveness signal does the sweeper use?** The per-context lock itself.
  `redis_adapter.scan_reactors` (`lib/ruby_reactor/storage/redis_adapter.rb:156`)
  enumerates stored contexts with their `status`. A context with
  `status == "running"` but **no live `async:<context_id>` lock** in Redis means
  the worker died (the lock auto-extends every `ttl/3` while alive, so its absence
  is the death signal). The sweeper re-enqueues those by id. One mechanism, two
  holes closed. See "Risk minimization".
- **Storage format compatibility / schema versioning?** The stored format is
  **already identical** to the job payload and to what `Reactor.find` / the web
  API read (`ContextSerializer`, `SCHEMA_VERSION = "1.0"`). Making storage
  load-bearing introduces **no new format**. The risk is the *strictness*:
  `SchemaVersionError` is a permanent, non-retried failure
  (`lib/ruby_reactor/sidekiq_workers/worker.rb:23`). With longer-lived stored
  contexts, a deploy that bumps the schema can strand in-flight reactors. See
  "Risk minimization".
