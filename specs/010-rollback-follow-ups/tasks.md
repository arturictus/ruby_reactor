---

description: "Task list for 010 Rollback and Resume Follow-ups"
---

# Tasks: Rollback and Resume Follow-ups

**Input**: Design documents from `specs/010-rollback-follow-ups/`

**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md),
[data-model.md](data-model.md), [contracts/](contracts/), [quickstart.md](quickstart.md)

**Tests**: REQUIRED by Constitution III (test-first, real Redis). In every phase, write the spec tasks
first and confirm they FAIL on the current code before implementing.

**Citations**:

- research decisions: `R-nn`;
- data-model sections: `DM §n`;
- protocol invariants and sequences: `J-n` / `P-n` (contracts/resume-protocol.md);
- API contract: `API §n` (contracts/api-surface.md).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: US1–US7 from spec.md

## Path Conventions

Single gem project: `lib/ruby_reactor/`, `spec/`, `demo_app/`, `gui/`, `documentation/`.

**Test rules**:

- Specs run against the test Redis at `redis://localhost:6780`.
- Async paths use `for_each_async_backend` (`spec/support/async_backends.rb`) plus
  `drain_async_jobs`. Single-job stepping uses `QueueProbe.next_job` / `QueueProbe.pending`
  (`spec/support/queue_probe.rb`).
- Concurrency specs use real threads with `ResumeFixtures.latch` / `ResumeFixtures.barrier` (T001),
  never stubs of Redis or of the lock.
- Add no new `Sidekiq::Testing.inline!`, except the one US4 example (T033), justified in plan.md
  Complexity Tracking.
- Don't run the gem suite and the demo suite at the same time: they flush the same Redis. If another
  worktree's suite shares the test Redis, rerun failures alone first.
- Demo specs locally: `cd demo_app && REDIS_URL=redis://localhost:6780/5 RAILS_ENV=test bundle exec rspec …`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: test scaffolding shared by the resume and liveness specs.

- [X] T001 Create `spec/support/resume_fixtures.rb`, module `ResumeFixtures`, on top of
  `RollbackRecorder` (`spec/support/rollback_recorder.rb`).

  Helpers:

  - `ResumeFixtures.latch`: returns an object with `#wait(timeout = 5)` and `#open!`, backed by a
    `Queue`. It blocks a step body until the spec opens it, raises if the timeout passes, and
    `open!` is idempotent.
  - `ResumeFixtures.barrier(n)`: `#wait` releases all `n` threads together (`Mutex` +
    `ConditionVariable`).
  - `ResumeFixtures.reset!`: clears every latch and the shared counters. Call it from a
    `before` hook that the file registers.

  Reactors: one constant each, class-based steps, with the `RollbackRecorder` tag set:

  | Constant | Definition |
  | --- | --- |
  | `LockedApproval` | `with_lock { "resume-fx:locked" }`; `recording_step :a`; `interrupt(:approval) { wait_for :a; validate { required(:ok).filled(:bool) } }`; `recording_step :c, after: :approval` |
  | `SemaphoredApproval` | same, with `with_semaphore(limit: 1) { "resume-fx:sem" }` |
  | `PlainApproval` | `LockedApproval` without the lock |
  | `BackgroundApproval` | `interrupt :approval, resume: :background`, otherwise as `PlainApproval` |
  | `DualApproval` | `recording_step :prep`; `interrupt(:a) { wait_for :prep }`; `interrupt(:b) { wait_for :prep }`; `recording_step :after_a, after: :a` (waits on `ResumeFixtures.latch(:after_a)` when it exists); `recording_step :done` depending on `:after_a` and `:b` (use `argument :x, result(:after_a)` and `argument :y, result(:b)`) |
  | `ManyApprovals.build(n)` | `n` interrupts `:i0..:i(n-1)` after `:prep`, and a final step depending on all of them |
  | `SlowSync` | `recording_step :slow`, which waits on `ResumeFixtures.latch(:slow)` and increments `ResumeFixtures.counter(:slow)` |
  | `SyncFanOut` | `recording_step :a` → `map :m` (fan-out, `batch_size 2`, element `RollbackRecorder` element with one recording step) → `recording_step :b, after: :m` → `recording_step :c, after: :b` |

  Check the interrupt validation DSL against `lib/ruby_reactor/dsl/interrupt_builder.rb`
  (`validate` / `validate_payload`).
- [X] T002 [P] Baseline, with no file changes. Run `bundle exec rspec` and record the pass/pending
  counts in a draft PR description (`specs/010-rollback-follow-ups/pr-description.md`). It is the
  regression bar for T078.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: run ownership (lock, then load) and the per-interrupt resume claim.

- Part A blocks US1, US2, US3, US5 and US6.
- Part B blocks US3, US4 and US5.
- US7 needs neither.

**⚠️ CRITICAL**: complete Part A before any story, and Part B before US3–US5.

### Part A: run ownership (R-02, R-03, R-06, R-09)

#### Specs first

- [X] T003 [P] Write `spec/ruby_reactor/worker_lock_then_load_spec.rb` (R-02, R-06, J-2),
  `for_each_async_backend`, with a `running` context stored for a simple two-step reactor.

  Lock, then load:

  - (a) Spy (`and_call_original`) on `RubyReactor::Lock#acquire` and on
    `storage.retrieve_context`. In `Worker#perform`, the `lock:async:<id>` acquire happens before
    the first `retrieve_context`.
  - (b) `hold_lock("async:<id>", owner: "other")` with `stub_const("RubyReactor::Worker::CONTEXT_LOCK_WAIT", 0.2)`:
    - `perform` calls neither `retrieve_context` nor `store_context`;
    - exactly one snooze is enqueued (`perform_in`) with `snooze_count + 1`;
    - `escalate_snooze` is never called, even with `snooze_count` above `lock_snooze_max_attempts`
      (uncapped).

  Status table (R-06):

  - (c) For each stored status `completed`, `failed`, `cancelled`, `aborted`, `halted`:
    `Executor#resume_execution` is not called, and afterwards
    `storage.lock_held?("async:<id>")` is false.
  - (d) For `paused` with no claims: `resume_execution` is not called, and the stored blob is
    unchanged byte for byte.

  Release and inline mode:

  - (e) The lock is released after a normal `perform`, and after the deserialization-failure path
    (store a blob with an unknown `schema_version`).
  - (f) Inside `Sidekiq::Testing.inline!` (an existing pattern, assertion only),
    `Lock#acquire` is never called for `async:`. Sidekiq backend only.

  It must FAIL on current code: (a), (b), (c) and (d) fail.
- [X] T004 [P] Extend `spec/ruby_reactor/context_lock_spec.rb` (R-03): with owner `"outer"`
  holding `async:<id>` through `RubyReactor::Lock.new("async:<id>", owner: "outer").acquire`, an
  `Executor` given `context_lock_owner = "outer"`:
  - runs `resume_execution` to completion with no `ContextLockContention`;
  - after it returns, the lock is still held (`lock_held?` true);
  - after the outer `release`, the lock is free.

  It fails on current code (`NoMethodError` on the writer).
- [X] T005 [P] Write `spec/ruby_reactor/rollback/undo_reload_spec.rb` (R-09).
  - Pause a reactor with three recording steps before an interrupt; `reactor = Klass.find(id)`.
  - Then simulate a newer save by another owner: load the context again, change it, and store it
    with `storage.store_context`. The change: `a`, `b`, `c` on the undo stack (the stale snapshot
    has only `a`, `b`), with `c` set in `intermediate_results`.
  - Call `reactor.undo`: the log shows `undo:c undo:b undo:a`, and the run ends `cancelled`.
  - Also: `reactor.undo(failure: { message: "x" })` ends `failed` with `failure_reason[:message] == "x"`.

  It fails on current code: `c` is not undone, and the keyword does not exist.

#### Implementation

- [X] T006 In `lib/ruby_reactor/executor.rb`, add `attr_writer :context_lock_owner` (R-03).
  `acquire_context_lock` already uses `@context_lock_owner ||= SecureRandom.uuid`. Add a comment
  explaining the re-entry: the outer holder releases last. T004 passes.
- [X] T007 Restructure `Worker#perform` in `lib/ruby_reactor/worker.rb` as "lock, then load"
  (R-02, R-06).

  Lock:

  - Add `CONTEXT_LOCK_WAIT = 2` with a comment (it matches `Map::Collector::COLLECT_LOCK_WAIT`;
    the caller is milliseconds from releasing).
  - Unless inline testing mode (reuse the executor's check), take
    `RubyReactor::Lock.new("async:#{context_id}", owner: SecureRandom.uuid, ttl: config.context_lock_ttl, wait: CONTEXT_LOCK_WAIT, auto_extend: true)`.
  - On `Lock::AcquisitionError`: call `handle_snooze(context_id, reactor_class_name, nil, snooze_count, Lock::ContextLockContention.new(e.message, context_lock_key: "async:#{context_id}"))`
    and return. Check that `handle_snooze` never touches `context` on the uncapped path.

  Load and dispatch by status:

  - Then `retrieve_context`. Return on `nil`.
  - Return when the status is in `TERMINAL_STATUSES`. Add `"halted"` to the constant.
  - Return when the status is `paused` (Part B refines this in T013).
  - Deserialize as today, and set `executor.context_lock_owner = lock.owner` before calling
    `resume_execution` / `resume_rollback`.
  - Release the lock in an `ensure` around everything after the acquire.

  T003 passes.
- [X] T008 In `lib/ruby_reactor/reactor.rb#undo` (R-09):
  - after `acquire_undo_lock`, reload: `@context = self.class.find(@context.context_id).context`;
  - add the keyword `failure: nil`. When it is given, after `undo_all` set `@context.status =
    "failed"` and `@context.failure_reason = failure` instead of leaving it for `cancel`, and save
    before the lock is released;
  - in `self.undo(id)`, keep calling `cancel` only on the non-failure path.

  Run the existing `spec/ruby_reactor/undo_spec.rb`, `spec/ruby_reactor/interrupt_undo_spec.rb` and
  `spec/ruby_reactor/rollback/distributed_map_rollback_spec.rb` unchanged. T005 passes.

### Part B: resume claims (R-04, DM §2, §3)

#### Specs first

- [X] T009 [P] Write `spec/ruby_reactor/interrupt_claims_spec.rb`:

  Storage:

  - (a) `claim_interrupt_resume(id, klass, :approval, json)` returns true, then false for a second
    claim. `TTL` equals `durability_ttl`.
  - (b) `retrieve_interrupt_resumes(id, klass, %w[a b])` returns only the claimed steps.
  - (c) `increment_interrupt_attempts` returns 1, then 2, with `TTL` set.

  `RubyReactor::InterruptClaims` (with `ResumeFixtures::DualApproval` paused at `a` and `b`):

  - (d) `claim!` stores the serialized payload.
  - (e) `unapplied(context)` lists only interrupts without a result.
  - (f) `apply!(context)` sets `intermediate_results[:b]` from a claim and returns `[:b]`.

  Executor and Worker:

  - (g) Store a claim for `b` directly, then run `Executor#resume_execution` through a `Worker`
    job (fake mode): `b`'s result equals the claimed payload in the stored context, and the run
    pauses again at `a`.
  - (h) `Worker#perform` on a `paused` run with an unapplied claim resumes it.

  Fails on current code.

#### Implementation

- [X] T010 [P] Storage (DM §2, §3):
  - In `lib/ruby_reactor/storage/redis_adapter.rb`:
    - `claim_interrupt_resume(context_id, reactor_class_name, step_name, serialized_payload)`:
      `SET NX EX durability_ttl` on `"#{context_key(context_id, reactor_class_name)}:resume:#{step_name}"`.
      Returns a Boolean; add the `rubocop:disable Naming/PredicateMethod` comment as
      `claim_map_owner_signal` has.
    - `retrieve_interrupt_resumes(context_id, reactor_class_name, step_names)`: one `MGET`, returns
      `{ "step" => serialized }` for the present keys.
    - `increment_interrupt_attempts(context_id, reactor_class_name, step_name)`: `MULTI` with
      `INCR` and `EXPIRE durability_ttl` on `...:resume_attempts:<step>`. Returns the Integer.
  - Declare all three in `lib/ruby_reactor/storage/adapter.rb`, with doc comments.

  T009 (a)–(c) pass.
- [X] T011 Create `lib/ruby_reactor/interrupt_claims.rb`, module `RubyReactor::InterruptClaims`
  (R-04), with module functions:
  - `claim!(context, step_name, payload)`: serialize with `ContextSerializer.serialize_value`
    plus `JSON.generate`, then call the storage claim. Returns a Boolean.
  - `unapplied(context)`:
    - interrupt steps of `context.reactor_class.steps` (`config.interrupt?`) with no
      `context.has_result?`;
    - one `retrieve_interrupt_resumes` call;
    - returns `{ step_sym => payload }`;
    - returns `{}` with no storage call when the reactor declares no interrupts.
  - `apply!(context)`: calls `context.set_result` for each unapplied claim; returns the names.

  Use `RubyReactor.reactor_storage_name(context.reactor_class)` for the class name. T009 (d)–(f)
  pass.
- [X] T012 In `lib/ruby_reactor/executor.rb#resume_execution`, right after `acquire_context_lock`,
  add `InterruptClaims.apply!(@context) if (@context.root_context || @context).equal?(@context)`.
  It runs before the reactor-level lock or semaphore, so a contended resume saves the applied
  payload (R-05 step 7, J-5). Comment that this is the only place a claim enters a context.
- [X] T013 In `lib/ruby_reactor/worker.rb`, refine the `paused` branch from T007: return only when
  `InterruptClaims.unapplied(context).empty?`, after deserializing; otherwise call
  `resume_execution` (R-06). T009 (g) and (h) pass.

**Checkpoint**: run `bundle exec rspec spec/ruby_reactor spec/map`: no regressions against T002.

---

## Phase 3: User Story 1 - The recovery sweep never runs a live caller-process run twice (Priority: P1) 🎯 MVP

**Goal**: a run executing in the caller's process is live to the sweeper while its process is alive,
and recovered after its liveness lapses (FR-001 to FR-004, R-01, J-1, J-3).

**Independent Test**: quickstart §1.

### Tests for User Story 1

- [X] T014 [P] [US1] Write `spec/ruby_reactor/caller_process_liveness_spec.rb`, in fake mode:
  - (a) `ResumeFixtures::SlowSync` runs in a thread. Wait until `async:<id>` is held (poll
    `storage.lock_held?`, at most 2s). `RubyReactor::Sweeper.run_once` returns 0 and enqueues no
    `Worker` job. Open the latch: `ResumeFixtures.counter(:slow) == 1`, the run is `completed`, and
    the lock is free.
  - (b) Same with `RubyReactor.configuration.context_lock_ttl = 1` (restore it in `after`). The
    step blocks for 3s while the spec calls `Sweeper.run_once` every 0.5s: always 0.
  - (c) `:fork`-tagged.
    - `pid = fork { RubyReactor.configuration.context_lock_ttl = 1; ResumeFixtures::SlowSync.run({}) }`.
    - Wait until a `running` context of that class exists, then `Process.kill(:KILL, pid)` and
      `Process.wait(pid)`.
    - Within 3s, `Sweeper.run_once` returns 1 for it.
    - redis-client reconnects after fork. If CI lacks `fork`, skip with
      `skip unless Process.respond_to?(:fork)`.
  - (d) `ResumeFixtures::SyncFanOut` returns a `DispatchResult`; afterwards `lock_held?` is
    false.
  - (e) A step raising `Interrupt` leaves the run `aborted` with the lock released, and
    `Sweeper.run_once` returns 0.
  - (f) Order: a spy on `Lock#release` for `async:<id>` and on `storage.store_context` shows the
    last store before the release.

  (a), (b), (c) and (f) fail on current code.
- [X] T015 [P] [US1] (Landed in `spec/ruby_reactor/caller_process_liveness_spec.rb`, next to the other US1 examples.) Extend `spec/ruby_reactor/context_lock_spec.rb`: while `SlowSync` blocks in a
  thread, `Reactor.undo(id)` (with `stub_const("RubyReactor::Reactor::UNDO_LOCK_WAIT", 0.2)`) raises
  `RubyReactor::Lock::AcquisitionError`, and the run then completes normally.

### Implementation for User Story 1

- [X] T016 [US1] In `lib/ruby_reactor/executor.rb#execute` (R-01):
  - after `input_validator.validate!` and before `reset_held_lock_keys!`, add
    `acquire_context_lock unless @context.inline_async_execution`. The method already limits itself
    to the root executor and to non-inline-testing mode;
  - in `ensure`, after the existing `save_context if persist_context? && !skip_context_persist?`,
    add `@acquired_context_lock&.release; @acquired_context_lock = nil`. Save before release
    (J-3), with a comment citing R-01 and 009 R-13;
  - extend the comment on `acquire_context_lock`, which says "Only the root executor holds it":
    a caller-process run holds it too.

  T014 and T015 pass. Then run `spec/ruby_reactor/sweeper_spec.rb`,
  `spec/ruby_reactor/sweeper_entrypoints_spec.rb`, `spec/compose_spec.rb`, `spec/map` and
  `spec/ruby_reactor/rollback`.
- [X] T017 [US1] Documentation (R-17):
  - README "Durability & Recovery": a paragraph saying a synchronous run holds the liveness lock
    while it executes, so the sweeper never re-runs it, and a killed process is recovered after
    `context_lock_ttl`;
  - `documentation/background_and_async.md` (sweeper section): the same;
  - `CHANGELOG.md` Bug Fixes entry.

**Checkpoint**: US1 is independently shippable.

---

## Phase 4: User Story 2 - A caller's last save never overwrites a worker's progress (Priority: P1)

**Goal**: FR-005 to FR-007 through J-1 to J-3 (T007, T016). P-1.

**Independent Test**: quickstart §2.

### Tests for User Story 2

- [X] T018 [P] [US2] Write `spec/ruby_reactor/executor/caller_save_race_spec.rb`, in fake mode,
  Sidekiq backend.
  - Register a test middleware on `ResumeFixtures::SyncFanOut` (or a subclass defined in the spec)
    whose `on(:complete_step, name, result, ctx)` runs only for `:m` with a `DispatchResult`. It
    performs queued jobs one at a time (`QueueProbe.next_job.perform!`) until the owner `Worker` job
    has been performed **once**, with `stub_const("RubyReactor::Worker::CONTEXT_LOCK_WAIT", 0.1)`.
  - Assert, inside the hook:
    - that `Worker` perform made no `storage.store_context` call for the run id (a spy counting
      calls between hook entry and exit, by Worker class);
    - a snooze job for the run is pending.
  - After `SyncFanOut.run` returns: `drain_async_jobs`. Then:
    - the run is `completed`;
    - `RollbackRecorder.log` contains `run:b` and `run:c` exactly once each.
  - Variant (FR-005): the same with an inline `continue`. Use a subclass that pauses at an
    interrupt before `:m`, then `continue` drives the run into the fan-out map.
  - Variant (FR-007): no hook. The run completes as before.

  Regression proof: write it first, confirm it **passes** after T007 and T016, then temporarily
  revert T016's lock in `execute` and see it fail (the overwrite leaves `running`, or runs `b`
  twice). Note that observation in the PR description draft; don't commit the revert.

### Implementation for User Story 2

- [X] T019 [US2] No new library code is expected. If T018 fails with T007 and T016 in place, fix
  the save/release order at the failing holder and cite J-3 in a comment.
- [X] T020 [US2] Documentation:
  - `documentation/background_and_async.md` "Durability" or Worker section: "a Worker takes the
    run's liveness lock before it reads the run (waits up to 2s), so it always sees the last save
    of whoever held it";
  - `CHANGELOG.md` Bug Fixes entry.

**Checkpoint**: US1 and US2 together close the caller-process ownership gaps.

---

## Phase 5: User Story 3 - A resume that meets a held lock is accepted, not lost (Priority: P1)

**Goal**: FR-008 to FR-014, R-05, R-07, P-2, API §1.

**Independent Test**: quickstart §3.

### Tests for User Story 3

- [X] T021 [P] [US3] Write `spec/ruby_reactor/interrupts/contended_resume_spec.rb`,
  `for_each_async_backend`, with `ResumeFixtures::LockedApproval` paused.
  - (a) Inside `hold_lock("resume-fx:locked", owner: "another-run")`, `continue(payload: { ok: true })`:
    - returns a `RubyReactor::DispatchResult` with `execution_id == id`;
    - no error is raised;
    - `Klass.find(id).context.status == "running"`;
    - the logger receives one line matching
      `event="ruby_reactor.resume.deferred".*reason="lock".*key="resume-fx:locked"`;
    - one `Worker` job is pending.
  - (b) After the block (lock released): `drain_async_jobs`. Then `completed`, the result of
    `approval` equals `{ ok: true }`, and the log is `run:a run:c`.
  - (c) An invalid payload (`{ ok: "nope" }`) inside `hold_lock`:
    - `Klass.continue` raises `InputValidationError`, and the instance method returns a `Failure`
      with `invalid_payload?`;
    - the run stays `paused`;
    - `QueueProbe.pending` is empty;
    - `retrieve_interrupt_resumes` is empty.
  - (d) After (a), a second `continue` raises `ValidationError` matching `/already resumed/`.
  - (e) The same as (a) and (b) with `SemaphoredApproval`, holding the semaphore's only slot through
    `RubyReactor::Semaphore.new("resume-fx:sem", limit: 1).acquire`.
  - (f) After (a), `Klass.cancel(id:, reason:)` and then drain: the Worker does nothing, the status
    stays `cancelled`, and the log has no `run:c`.
  - (g) `BackgroundApproval`: `continue` returns a `DispatchResult` with status `running`, and the
    log line has `reason="background"`; draining completes it.
- [X] T022 [P] [US3] Write `spec/ruby_reactor/worker_snooze_admitted_spec.rb` (R-07, J-8),
  `for_each_async_backend`, with `lock_snooze_max_attempts = 2` (restore it after).
  - (a) Run (a) of T021 while holding the lock, then perform the Worker job 4 times
    (`QueueProbe.next_job`):
    - the run is never `failed`;
    - exactly one `ruby_reactor.resume.waiting` warning is logged, carrying `snooze_count=2`;
    - after release and drain, it is `completed`.
  - (b) Unchanged: an async (`background all: true`) reactor's **first** run that contends on its
    lock 3 times is escalated to `failed`, as today.
- [X] T023 [P] [US3] Update `spec/ruby_reactor/rollback/resume_guard_spec.rb`:
  - The "reactor lock" and "reactor semaphore" contention examples now expect a `DispatchResult`
    and status `running`, and completion after release plus drain. Rename the describe text from
    "contended resume raises" to "contended resume is deferred".
  - `CompensatingResume` now expects the rejection message `/already resumed/` (its interrupt has a
    result and a claim). The log expectation is unchanged.
  - Keep the `aborted` and finished-run rejections unchanged.

### Implementation for User Story 3

- [X] T024 [US3] Rewrite `Reactor#continue` in `lib/ruby_reactor/reactor.rb` (R-05; keep each
  method under RuboCop's limits by extracting private helpers).

  Steps:

  1. `ensure_resumable!(step_name)`:
     - raise `ValidationError` as today when there is no `current_step`, when the run is
       `cancelled`, and when the status is not `paused` or `running`;
     - for this phase, `running` still raises the existing message; T039 opens it;
     - `validate_continue_step!(step_name)`;
     - raise `"Cannot resume: interrupt :#{step_name} was already resumed"` when
       `@context.has_result?(step_name)`.
  2. `if (failure = validate_continue_payload(payload, step_name)) then return failure`
     (unchanged in this phase).
  3. Claim:
     `raise Error::ValidationError, "Cannot resume: interrupt :#{step_name} was already resumed" unless InterruptClaims.claim!(@context, step_name, payload)`.
  4. `lock = try_run_lock`, a new private method: a `RubyReactor::Lock` on `async:<id>` with
     `wait: 0` and `auto_extend: true`. It returns `nil` in inline testing mode and `:contended` on
     `AcquisitionError`. On `:contended`, `return hand_off_resume(step_name, reason: :run_busy)`.
  5. Reload: `@context = self.class.find(@context.context_id).context`. If it is now finished or
     `cancelled`, release and raise as step 1 would.
  6. If the step's `background_resume?`:
     - `InterruptClaims.apply!(@context)`;
     - status `:running`;
     - `Executor.middlewares_for(self.class).on(:before_async_enqueue, @context)`;
     - `save_context`;
     - release, then `return hand_off_resume(step_name, reason: :background)`.
  7. Otherwise: `executor = Executor.new(self.class, {}, @context)`, then
     `executor.context_lock_owner = lock&.owner`, then `@result = executor.resume_execution`, and
     copy the context and traces back, as today.
  8. `rescue Lock::AcquisitionError, Semaphore::AcquisitionError => e` (a `ContextLockContention`
     cannot occur once the lock is owned; let it re-raise if it does):
     - release the run lock **first**;
     - `return hand_off_resume(step_name, reason: e.is_a?(Semaphore::AcquisitionError) ? :semaphore : :lock, key: <the key>)`.
     - The key comes from the reactor's `lock_config` or `semaphore_config` `key_proc` applied to
       `@context.inputs`.
  9. `ensure`: release the lock if it is still held (idempotent).

  `hand_off_resume(step_name, reason:, key: nil)` logs
  `event="ruby_reactor.resume.deferred" reactor= context_id= step= reason= key=`, calls
  `configuration.async_router.perform_async(id, RubyReactor.reactor_storage_name(self.class))`, and
  returns `check_for_inline_completion || @result`, where `@result` is the router's
  `DispatchResult`.

  Delete `reopen_paused`, the `past_gates?` rescue branch and `enqueue_background_resume` (folded
  into step 6). Keep `Executor#past_gates?` only if another caller uses it; grep first. T021
  (a)–(e) and (g) pass.
- [X] T025 [US3] In `Worker#handle_snooze` (`lib/ruby_reactor/worker.rb`, R-07):
  - set `capped &&= !context&.admitted?`;
  - when an uncapped admitted run reaches `snooze_count == max` (only then), log at warn
    `event="ruby_reactor.resume.waiting" reactor= context_id= key= snooze_count=`. The key comes
    from `error.message` or `error.context_lock_key`; take the reactor-level key from the error
    message if there is no accessor;
  - comment: escalation marks `failed` without rollback, so it applies only before admission (J-8).

  T022 passes.
- [X] T026 [US3] In `lib/ruby_reactor/web/api.rb`, the `continue` route: a `DispatchResult`
  answers `{ success: true, message: "Resume accepted" }`, and a `ValidationError` answers 422 with
  its message, as today. Add the example to the existing web API spec under
  `spec/ruby_reactor/web/` (find the file covering `POST .../continue`).
- [X] T027 [US3] RSpec surface (R-18, API §7), in `lib/ruby_reactor/rspec/test_subject.rb` and
  `lib/ruby_reactor/rspec/matchers.rb`:
  - `TestSubject#resume(payload: {}, step: nil, process_jobs: nil)`:
    - keep the result of `@reactor_instance.continue` in `@last_resume_result`;
    - process jobs only when `process_jobs.nil? ? @process_jobs : process_jobs`.
  - Matcher `be_resume_deferred`: passes when `subject.last_resume_result` is a `DispatchResult`
    **and** the reloaded status is `running`, with a failure message naming the actual result class
    and status. Expose `last_resume_result` as a reader.
  - Specs in `spec/ruby_reactor/rspec/` (new file `resume_deferred_matcher_spec.rb`).
- [X] T028 [P] [US3] Demo: `demo_app/app/reactors/contended_approval_demo_reactor.rb`, class
  `ContendedApprovalDemoReactor`, with class-based steps:
  - `with_lock { |inputs| "demo:approval:#{inputs[:request_id]}" }`;
  - step `:submit`, then `interrupt(:approve) { wait_for :submit; validate { required(:approved).filled(:bool) } }`,
    then step `:record`.
- [X] T029 [US3] Demo rake task `demo:contended_resume` in `demo_app/lib/tasks/demo_reactors.rake`,
  with a `desc`, depending on `[:environment, :flush_redis]`. It:
  - runs the reactor to the pause;
  - takes the reactor's lock as "another run" (`RubyReactor::Lock.new(key, owner: "other-run").acquire`);
  - calls `continue`, and prints "resume accepted (DispatchResult) while the lock is held" and the
    status;
  - releases the lock, then waits (poll `find(id)` for up to 30s) and prints the final status and
    the `approve` result.
- [X] T030 [US3] Demo spec `demo_app/spec/reactors/contended_approval_demo_reactor_spec.rb`,
  `type: :reactor`, shipped surface only:
  - `test_reactor(..., process_jobs: false)`, then `be_paused_at(:approve)`;
  - inside `hold_lock("demo:approval:1")`, `subject.resume(payload: { approved: true }, process_jobs: false)`,
    then `expect(subject).to be_resume_deferred`;
  - after the block, `drain_async_jobs`, a reload, `be_success`, and
    `subject.step_result(:approve)`;
  - an invalid payload inside `hold_lock` raises `InputValidationError`, and `be_paused` holds.
- [X] T031 [US3] Documentation:
  - `documentation/interrupts.md`, "Resuming Execution": validation first, the claim, the
    hand-off on contention, the `DispatchResult` return, the `resume.deferred` log line;
  - `documentation/locks_and_semaphores.md`:
    - line 136: replace "a contended resume raises and the run stays paused" with the deferral;
    - add the snooze-limit-before-admission rule (R-07) where `lock_snooze_max_attempts` is
      described;
  - README "Interrupts (Pause & Resume)" and "Locks, Semaphores & Ordered Locks": one sentence
    each;
  - `documentation/testing.md`: `resume(process_jobs:)` and `be_resume_deferred`;
  - `CHANGELOG.md`: the Bug Fixes entry, plus a **migration note** that `continue` returns a
    `DispatchResult` where it raised, and that background resumes are no longer escalated to
    `failed`.

**Checkpoint**: the US3 specs and demo spec are green; webhook-style resumes are never lost to
contention.

---

## Phase 6: User Story 4 - Two resumes of one interrupt at the same instant: exactly one wins (Priority: P2)

**Goal**: FR-015 and FR-016 through the claim (R-04, J-4, P-3).

**Independent Test**: quickstart §4.

### Tests for User Story 4

- [X] T032 [P] [US4] Write `spec/ruby_reactor/interrupts/resume_claim_spec.rb`, in fake mode.

  Race:

  - (a) 200 iterations. Each one:
    - pauses `ResumeFixtures::PlainApproval`;
    - starts two threads that `barrier.wait` and then call `Klass.continue` with payloads
      `{ ok: true, who: 1 }` and `{ ok: true, who: 2 }`;
    - collects the outcomes.

    In every iteration:

    - exactly one returns and one raises `ValidationError` `/already resumed/`;
    - the stored `approval` result equals the winner's payload;
    - `RollbackRecorder` counts `run:c` once.

  Loser and background resumes:

  - (b) The loser leaves no trace: the stored claim value is the winner's payload, and the context
    `updated` marker or `execution_trace` has only one resume's entries.
  - (c) With `BackgroundApproval` and two threads, exactly one `Worker` job is enqueued
    (`QueueProbe.enqueued`).
  - (d) Inline mode is covered by T033.
- [X] T033 [US4] Add to the same file the one justified inline example (plan.md Complexity
  Tracking):
  - `around { |ex| Sidekiq::Testing.inline! { ex.run } }`, Sidekiq backend only;
  - 50 iterations of (a), with the same assertions;
  - a comment citing FR-016, R-14 and why fake mode cannot show it (the context lock is taken
    there).

### Implementation for User Story 4

- [X] T034 [US4] No new library code is expected: the claim (T011) and `continue` steps 1 and 3
  (T024) implement it. If (a) fails because the loser wrote the context, make sure no
  `save_context` runs between the claim check and the lock (J-5). Confirm
  `validate_continue_payload` writes nothing on valid payloads.
- [X] T035 [US4] Documentation:
  - `documentation/interrupts.md`: "A second resume of the same interrupt, concurrent or later,
    raises `ValidationError` ("already resumed"), in every execution mode";
  - `CHANGELOG.md` Bug Fixes entry and migration note.

---

## Phase 7: User Story 5 - Resuming several pending interrupts at once (Priority: P2)

**Goal**: FR-017 to FR-021, through acceptance on `running`, the hand-off backstop, and claims
applied by the lock owner (R-05, R-06, R-08, P-4).

**Independent Test**: quickstart §5.

### Tests for User Story 5

- [X] T036 [P] [US5] Write `spec/ruby_reactor/interrupts/concurrent_interrupts_spec.rb`, in fake
  mode, with `ResumeFixtures::DualApproval`.
  - (a) Pause at `a` and `b`.
    - Thread 1: `continue(step_name: :a, payload: {...})`, where `after_a` blocks on
      `latch(:after_a)`.
    - Main thread: wait until the status is `running` and `async:<id>` is held, then
      `continue(step_name: :b, payload: {...})`. It returns a `DispatchResult`, and the log line
      has `reason="run_busy"`.
    - Open the latch and join thread 1, whose result is an `InterruptResult` (paused at `b`).
    - `drain_async_jobs`. Then `completed`; the `a` and `b` results are the payloads;
      `RollbackRecorder` counts `run:after_a` and `run:done` once each.
  - (b) `ResumeFixtures::ManyApprovals.build(n)` for n in 2..5: n threads resume all interrupts
    behind a barrier, then drain. Every call returns (no raise), the run is `completed`, and each
    interrupt's result is its payload.
  - (c) While `a`'s resume blocks, an invalid payload for `b`:
    - returns the validation failure;
    - stores no claim;
    - after the latch opens, `a`'s progress is intact (`run:after_a` recorded, the status ends
      paused at `b`);
    - `increment_interrupt_attempts` was called once, and the context blob has no
      `interrupt_attempts`.
  - (d) `a`'s resume fails in `after_a` (use a failing variant) after `b` was accepted:
    - drain; the run is `failed`;
    - the `b` result is never set;
    - the Worker made no `resume_execution` call.
  - (e) An async reactor (`background all: true` variant of `DualApproval`) is enqueued but not yet
    drained. `continue(step_name: :b)` while `running` (with `:prep` already done: enqueue after
    the first pause) returns a `DispatchResult`. Drain: the run does not stay paused at `b`.
- [X] T037 [P] [US5] Update `spec/integration/interrupt_max_attempts_spec.rb` and
  `spec/integration/interrupt_validation_spec.rb`:
  - attempts are counted by `increment_interrupt_attempts`, not
    `private_data[:interrupt_attempts]`;
  - reaching `max_attempts` ends the run `failed` with the same `failure_reason` keys (DM §3), and
    the completed steps undone;
  - add one example where `max_attempts` is reached while another resume holds the run: with
    `stub_const(...UNDO_LOCK_WAIT, 0.2)`, `continue` raises `Lock::AcquisitionError` and the run is
    not marked `failed` (API §1).
- [X] T038 [P] [US5] Run the existing `spec/ruby_reactor/multiple_interrupts_spec.rb`,
  `spec/ruby_reactor/interrupt_spec.rb` and `spec/ruby_reactor/async_notification_interrupt_spec.rb`
  unchanged, and record any expectation that encoded "running is rejected". Update only those, each
  citing FR-017.

### Implementation for User Story 5

- [X] T039 [US5] In `Reactor#ensure_resumable!` (T024), accept `running` alongside `paused`
  (FR-017). Rejections stay: finished, `aborted`, `rolling_back`, cancelled, not ready, already
  resumed (FR-020). Update the error message for other statuses: "the reactor is <status>; only a
  paused or running run accepts a resume".
- [X] T040 [US5] Rewrite `Reactor#validate_continue_payload` (R-08):
  - replace the `private_data[:interrupt_attempts]` increment and its `save_context` with
    `current_attempts = configuration.storage_adapter.increment_interrupt_attempts(id, storage_name, step_key)`;
  - at `max_attempts`, call `undo(failure: { message:, step_name:, errors:, payload:, step_arguments:, attempts:, validation_errors: })`
    (T008) instead of `undo` followed by a separate failed save;
  - return the same `Failure`.

  T036 (c) and T037 pass.
- [X] T041 [US5] `TestSubject#resume` (`lib/ruby_reactor/rspec/test_subject.rb`): accept a
  `running` subject when `ready_interrupt_steps` includes the step. Keep the `paused?` error for
  other statuses, with the message updated to mirror T039. Spec in `spec/ruby_reactor/rspec/`.
- [X] T042 [P] [US5] Demo: `demo_app/app/reactors/dual_approval_demo_reactor.rb`, class
  `DualApprovalDemoReactor`, with class-based steps:
  - step `:prepare`;
  - `interrupt :finance, resume: :background` (`wait_for :prepare`);
  - `interrupt(:legal) { wait_for :prepare }`;
  - step `:approve_all` using `result(:finance)` and `result(:legal)`.
- [X] T043 [US5] Demo rake task `demo:concurrent_interrupts`, with a `desc`:
  - run to the pause, printing the ready interrupts;
  - `continue(:finance)`: print "finance accepted (background)" and the status `running`;
  - immediately `continue(:legal)`: print "legal accepted while running" and the result class;
  - poll up to 30s, then print the final status and `approve_all`'s result.
- [X] T044 [US5] Demo spec `demo_app/spec/reactors/dual_approval_demo_reactor_spec.rb`, shipped
  surface only:
  - `have_ready_interrupts(:finance, :legal)`;
  - `resume(step: :finance, payload:, process_jobs: false)`, then `be_resume_deferred`;
  - `resume(step: :legal, payload:, process_jobs: false)`, then `be_resume_deferred`;
  - `drain_async_jobs`, then `be_success`, and both results present.
- [X] T045 [US5] Documentation:
  - `documentation/interrupts.md`, the multiple-interrupts section: resumes for different ready
    interrupts are accepted while the run executes, and applied once. Describe the hand-off and the
    transient `paused` state. Note that in inline job-testing mode, overlapping resumes need real
    workers (R-14);
  - `documentation/interrupts.md`: the attempt counter's new home, and the restart for runs paused
    across the upgrade;
  - README "Interrupts" one-liner;
  - `CHANGELOG.md` entry, plus the migration note on the attempt counts.

---

## Phase 8: User Story 6 - Manual undo finishes a compensate that was cut off (Priority: P2)

**Goal**: FR-022 to FR-026 (R-10, R-11, J-9, P-5).

**Independent Test**: quickstart §6.

### Tests for User Story 6

- [X] T046 [P] [US6] (Landed as `spec/ruby_reactor/rollback/aborted_compensate_spec.rb`, beside `aborted_execution_spec.rb`.) Extend `spec/ruby_reactor/rollback/aborted_execution_spec.rb`, caller process.

  Fixtures:

  - `recording_step :a`;
  - `recording_step :x, after: :a, fail: true`. Its `compensate` records `compensate-start:x`,
    raises `SignalException.new("TERM")` the first time it runs (a class-level flag), and the
    second time records `compensate:x(<arguments>, <reason class>/<reason message>)`;
  - the step's arguments include `id: 7`.

  Examples:

  - (a) `run` raises `SignalException`:
    - the stored status is `aborted`;
    - `rollback` has `step: "x"`, `compensated: false` and `arguments` including `id: 7`;
    - `error["message"]` is the failure message.
  - (b) `Klass.undo(id)`: the log continues `compensate-start:x compensate:x(... id: 7 ...) undo:a`;
    the status is `cancelled`; the `rollback` field is cleared.
  - (c) The interruption comes in `a`'s undo, after `x`'s compensate returned: `rollback` carries
    no `arguments`, and manual undo logs only `undo:a`, with no `compensate`.
  - (d) The re-run `compensate` returns `Failure("nope")`:
    - `undo:a` still runs;
    - a `:compensate` trace entry records the failure;
    - a test middleware receives `:failed_compensation` for `:x`.
  - (e) A string failure reason (`Failure("plain")`) is passed again as the string `"plain"`. An
    exception reason is passed as `RubyReactor::Error::RecordedFailure`, with `message` and
    `original_class`.
  - (f) Depth: the same failing step inside a composed child (compose step in the root); manual
    undo of the root re-runs `x`'s compensate before the child's `undo:` entries, then the root's.
  - (g) Depth: inside an inline map element (map of 2 elements; element 1 fails at `x`). Manual
    undo re-runs element 1's `compensate:x` before its own undos, and element 0 is undone as
    today.
- [X] T047 [P] [US6] (Landed in `aborted_compensate_spec.rb`, "the dashboard API".) API spec, in the existing web API spec file under `spec/ruby_reactor/web/`:
  - `GET /api/reactors/:id` for the aborted run of T046 (a) includes
    `"pending_compensation" => { "step" => "x" }`;
  - after manual undo, the key is absent;
  - for an aborted run with no pending compensate, the key is absent.

### Implementation for User Story 6

- [X] T048 [P] [US6] Create `lib/ruby_reactor/error/recorded_failure.rb`:
  `RubyReactor::Error::RecordedFailure < StandardError`, with `attr_reader :original_class`,
  initialized as `new(message, original_class:)`. A doc comment says it is the reason a re-run
  `compensate` receives, because the original exception cannot be rebuilt (R-10).
- [X] T049 [US6] In `lib/ruby_reactor/executor/compensation_manager.rb#handle_step_failure`, keep
  `arguments: step_config.rollback_arguments(arguments)` on `@pending`. Add the helper
  `pending_record` that returns:
  - `{ "trigger" => "failure", "step" => name.to_s, "compensated" => false, "arguments" => ContextSerializer.serialize_value(args), "error" => serialized_error, "failures" => serialize(rollback_failures) }`
    while the pending compensate has not returned;
  - `nil` otherwise.

  `serialized_error` is the `String` itself, or `{ "class" => e.class.name, "message" => e.message }`.
- [X] T050 [US6] In `lib/ruby_reactor/executor.rb#mark_aborted`: when it is about to set
  `:aborted`, also `@context.rollback = @compensation_manager.pending_record if @compensation_manager.pending_record`
  (R-10). Check that the `rescue Exception` and `aborting_on_interruption` paths both reach it,
  for the root and for a composed child's own executor.
- [X] T051 [US6] In `lib/ruby_reactor/executor.rb#undo_all`, before
  `@compensation_manager.rollback_completed_steps`, add the private `compensate_pending!`:
  - if `@context.rollback` has `"arguments"`, a `"step"` naming a step of this reactor, and
    `"compensated" == false`:
    - rebuild the reason: the string, or `Error::RecordedFailure.new(h["message"], original_class: h["class"])`;
    - `@compensation_manager.compensate(step_config, reason, ContextSerializer.deserialize_value(args))`;
    - then set `@context.rollback["compensated"] = true`.

  It must not run for 009's hand-off states, which carry no `"arguments"`. Comment with J-9.
- [X] T052 [US6] In `lib/ruby_reactor/reactor.rb#undo` (after T008's reload), merge instead of
  overwrite:
  - `record = @context.rollback if @context.status.to_s == "aborted" && @context.rollback&.key?("arguments")`;
  - `@context.rollback = { "trigger" => "undo", "compensated" => true, "failures" => [] }.merge(record ? record.slice("step", "compensated", "arguments", "error") : {})`.

  T046 (a)–(g) pass. If (f) or (g) fail, check that `ComposeStep#undo` and `Map::ElementRollback`
  reach the child's `Executor#undo_all` with the child context that carries its own `rollback`.
- [X] T053 [US6] In `lib/ruby_reactor/web/api.rb`, the detail serialization (R-11): when the status
  is `aborted` and `rollback` is a Hash with `"arguments"` and `"compensated" == false`, add
  `"pending_compensation" => { "step" => rollback["step"] }`. T047 passes.
- [X] T054 [US6] GUI:
  - `gui/src/lib/reactors.ts`: add `pending_compensation?: { step: string }` to the reactor detail
    type;
  - `gui/src/components/ReactorDetail.tsx`: on `aborted` runs with it, show one amber line:
    "Compensation of step `<step>` did not finish; run undo to complete it.";
  - a vitest example in `gui/src/components/__tests__/`;
  - rebuild with `cd gui && npm run build`, which updates `lib/ruby_reactor/web/public/`. Commit
    the bundle.
- [X] T055 [US6] Documentation:
  - `documentation/interrupts.md`, the aborted section (around line 172);
  - `documentation/core_concepts.md`, around line 343: manual undo re-runs an unfinished failing
    `compensate` first, at any depth; the `compensate` must tolerate a repeat; the dashboard
    flag;
  - `CHANGELOG.md` Bug Fixes entry.

---

## Phase 9: User Story 7 - One bulk undo for a whole map (Priority: P3)

**Goal**: FR-027 to FR-034 (R-12, R-13, P-6, API §3).

**Independent Test**: quickstart §7.

### Tests for User Story 7

- [X] T056 [P] [US7] Write `spec/ruby_reactor/dsl/map_undo_all_dsl_spec.rb`:
  - `undo_all { |r| }` stores the block (the map step config's `arguments[:undo_all_block]`
    resolves to a Proc);
  - two declarations raise `RubyReactor::Error::ValidationError` naming the map;
  - `undo_all` without a block raises the same;
  - a map without it has no `undo_all_block` argument.
- [X] T057 [P] [US7] Write `spec/map/map_undo_all_spec.rb`, with fixtures from
  `spec/support/map_rollback_fixtures.rb`: extend `MapRollbackFixtures.parent` with
  `undo_all: nil` (a Proc). The block records `RollbackRecorder.record("undo_all:#{results.to_a.inspect}")`
  and returns its own option result.

  Fan-out (`for_each_async_backend`, `fan_out: true, batch_size: 5`, 20 elements, `b_fails: true`):

  - (a) One `undo_all:` entry with 20 results in index order.
  - (b) No `undo:e.*` entries.
  - (c) `QueueProbe.enqueued("RubyReactor::Adapters::Sidekiq::MapElementRollbackWorker")` (or its
    ActiveJob class) is 0 throughout.
  - (d) `undo:a` comes after `undo_all:`.
  - (e) The run is `failed`.
  - (f) The `:undo_all` trace entry has `count: 20`.
  - (g) Log lines `ruby_reactor.map.rollback.undo_all.started` and `.completed`, with `count=20`.

  Other cases:

  - (h) Atomic, element 7 fails: called with exactly the elements that have a success slot (the
    ones that completed before or while 7 failed), never index 7 or a skipped index, and the
    element's own compensate ran (`compensate:e.e2[7]`).
  - (i) Inline map (`fan_out: false`): the same as (a), (b), (d), (e) and (f).
  - (j) The block raises:
    - `have_rollback_failure(:m)` with `kind: :undo_all`;
    - `undo:a` still runs;
    - the final `Failure` lists it.
  - (k) The block returns `RubyReactor::Failure("x")`: the same, with `reason: :returned_failure`.
  - (l) Every element halts or is skipped: no `undo_all:` entry, and `undo:a` runs.
  - (m) A completed run, then `Klass.undo(id)`: exactly one `undo_all:` entry.
  - (n) An inline map element 1 interrupted (`ElemInterruptOnce`-style, raising in its forward
    step), so the run is `aborted`. Manual undo replays element 1's completed steps per element,
    and `undo_all` receives element 0's result only.
  - (o) Fan-out with one result slot deleted (`storage` `HDEL`) before rollback: one
    `context_unavailable` failure for that index, and `undo_all` receives the rest.
  - (p) `:slow`: 10,000 elements, fan-out, `batch_size 50`, a block that counts by iterating.
    - Count `== 10,000`.
    - Zero element undos.
    - Memory flat: `GC.stat(:heap_live_slots)` sampled every 1,000 items inside the block grows by
      less than 10% from the first to the last sample. Document the bound in the spec.

### Implementation for User Story 7

- [X] T058 [US7] In `lib/ruby_reactor/dsl/map_builder.rb`:
  - add `undo_all(&block)`:
    - raise `RubyReactor::Error::ValidationError.new("map :#{@name} undo_all needs a block", step: @name)`
      without a block;
    - raise `"map :#{@name} declares undo_all twice"` when `@undo_all_block` is already set;
    - store the block in `@undo_all_block`;
  - in `build_step_config`, add `undo_all_block: { source: RubyReactor::Template::Value.new(@undo_all_block) }`
    only when it is set.

  T056 passes.
- [X] T059 [US7] In `lib/ruby_reactor/step/map_step.rb`:
  - add `input :undo_all_block, optional: true`, so the declared argument is accepted;
  - in `compensate` (and therefore `undo`), add as the first branch:
    `return bulk_rollback(map_id, step_name, block) if (block = undo_all_block)`;
  - add the private `undo_all_block`, which reads the static declaration
    (`context.reactor_class.steps[context.current_step].arguments[:undo_all_block]&.dig(:source)&.value`,
    in the same style as `element_class`), because the undo record carries no arguments (009 R-14).
- [X] T060 [US7] In `lib/ruby_reactor/map/step_rollback.rb`, add `bulk_rollback(map_id, step_name, block)`
  (R-13):

  Collect the results:

  - **Fan-out** (`dispatched_map_id(step_name)`):
    - `total = metadata["count"]`, from `storage.retrieve_map_metadata`;
    - report missing slots as `rollback_entry(index, :context_unavailable, "context expired")`,
      checked in chunks of 1,000 with a new adapter `map_result_indexes_present(map_id, klass, indexes)`
      (`HMGET` or `HEXISTS` pipeline) declared in `lib/ruby_reactor/storage/adapter.rb`;
    - `enum = RubyReactor::Map::ResultEnumerator.new(map_id, klass, strict_ordering: true).lazy.select(&:success?).map(&:value)`.
      Check `wrap_result` for error, halt and skip markers, and exclude them;
    - `count` comes from a counting pass over the same lazy filter. Prefer a stored count if one
      exists, otherwise count in chunks.
  - **Inline**:
    - pass 1 over `retrieve_map_element_context_ids_from_tail` chunks (`Map::ROLLBACK_CHUNK`): for
      each `aborted` element, call `inline_element_rollback(...)` (per-element replay) and collect
      its failures; count the `completed` elements; report expired elements as `inline_rollback`
      does;
    - pass 2 is a lazy `Enumerator` over the same index in **index order** (from the head) that
      deserializes one context at a time and yields `completed` elements' results. Reuse the
      result reconstruction `RubyReactor::Reactor.new(element_context).result.value`.

  Call:

  - when `count.zero?`, skip the call;
  - otherwise `log_rollback("undo_all.started", step_name, count:)`;
    `outcome = block.call(enum)`, with `rescue RubyReactor::Error::Rescuable => e` → a failure;
  - a failure is `outcome.is_a?(RubyReactor::Failure)` or the raise. Add
    `{ step: step_name.to_sym, kind: :undo_all, reason: :raised | :returned_failure, message: }`;
  - `context.append_execution_trace(type: :undo_all, step: step_name, count:, result:, timestamp: Time.now)`;
  - `log_rollback("undo_all.completed", step_name, count:, failed:)`;
  - `finish_rollback(step_name, count, failures)`.

  T057 passes, except (p) until T061.
- [X] T061 [US7] Profile T057 (p). If memory grows, reduce what the lazy chain retains:
  `ResultEnumerator`'s `count` memoization is fine, and no `to_a` is allowed. Mark the chunk sizes
  with a `ponytail:` comment naming the bound.
- [X] T062 [US7] Matcher `have_run_undo_all(step_name)`, with chain `.with_elements(n)`, in
  `lib/ruby_reactor/rspec/matchers.rb`. It reads the subject's execution trace for
  `type: :undo_all, step: step_name`, and `count == n` when chained. Spec in
  `spec/ruby_reactor/rspec/`.
- [X] T063 [P] [US7] Demo reactors, one per file, class-based steps:
  - `demo_app/app/reactors/bulk_refund_charge_reactor.rb`: `BulkRefundChargeReactor`, an element
    with a `:charge` step returning `{ id:, amount: }`, and an `undo` that prints a per-element
    refund (it never runs here: proof that `undo_all` replaced it);
  - `demo_app/app/reactors/bulk_refund_demo_reactor.rb`: `BulkRefundDemoReactor`, with:
    - `map :charges`: fan-out, `batch_size 5`, `undo_all { |charges| BulkRefundDemoReactor.refunded << charges.map { _1[:id] } }`.
      `refunded` is a class-level array the rake task prints;
    - then a step `:settle` that fails when `inputs[:fail_settle]`.
- [X] T064 [US7] Demo rake task `demo:map_undo_all`, with a `desc`. It runs with
  `fail_settle: true`, waits for a terminal status (polling up to 60s), and prints:
  - "bulk refund called once with N charges";
  - the final status (`failed`);
  - confirmation that no per-element refund line printed.
- [X] T065 [US7] Demo spec `demo_app/spec/reactors/bulk_refund_demo_reactor_spec.rb`, shipped
  surface only:
  - `test_reactor(BulkRefundDemoReactor, { payments: 6.times.map { ... }, fail_settle: true })`,
    then `be_failure`, then `have_run_undo_all(:charges).with_elements(6)`;
  - `fail_settle: false`: `be_success`, and `have_run_undo_all(:charges)` is negated.
- [X] T066 [US7] Documentation:
  - `documentation/data_pipelines.md`: an `undo_all` section, covering contract, coverage,
    at-least-once, the fan-out path that uses no jobs, and aborted inline elements;
  - `demo_app/documentation/data_pipelines.md`: kept in sync;
  - README "Map & Parallel Execution": the example from API §3;
  - `documentation/testing.md`: `have_run_undo_all`;
  - `CHANGELOG.md`: a **Features** entry.

---

## Phase 10: Polish & Cross-Cutting Concerns

- [X] T067 Register `demo:rollback_follow_ups` in `demo_app/lib/tasks/demo_reactors.rake`, with a
  `desc`, depending on `[:environment, :flush_redis, :map_undo_all, :contended_resume, :concurrent_interrupts]`.
  Append `:rollback_follow_ups` to `demo:all`'s prerequisites.
- [X] T068 [P] `specs/future_improvements.md`:
  - remove the seven "Rollback follow-ups (008)" bullets;
  - in "Fenced context writes": strike the `Reactor#continue` and synchronous
    `Reactor.run` / `Executor#execute` rows of "Remaining writers", like the collector row, citing
    010 R-01, R-04 and R-05. Note that part 2 ("Lock, then load") is done for the `Worker`,
    `continue` and `Reactor#undo`.
- [X] T069 [P] Grep for stale claims:
  `grep -rn "contended resume raises\|run stays paused\|not paused at an interrupt\|interrupt_attempts" README.md documentation demo_app/documentation lib`.
  Fix every hit that contradicts 010, except the internal `private_data` legacy comment if one is
  kept.
- [X] T070 [P] Observability check (Constitution IV): every new log line is key=value with
  `reactor` and `context_id` (R-15). Add log-shape examples to
  `spec/ruby_reactor/interrupts/contended_resume_spec.rb` (`resume.deferred`),
  `spec/ruby_reactor/worker_snooze_admitted_spec.rb` (`resume.waiting`) and
  `spec/map/map_undo_all_spec.rb` (`undo_all.*`) if not already covered.
- [ ] T071 Run `bundle exec rubocop` and fix offences. No `--disable-pending-cops`.
- [ ] T072 Run the full gem suite, `bundle exec rspec`, alone on the test Redis. Compare with T002:
  no new failures. Pending examples are allowed only for the documented `future_improvements`
  items.
- [ ] T073 Run the `:slow` and `:fork` tags explicitly:
  `bundle exec rspec --tag slow spec/map/map_undo_all_spec.rb` and
  `bundle exec rspec --tag fork spec/ruby_reactor/caller_process_liveness_spec.rb`.
- [ ] T074 [P] GUI: run `cd gui && npm run lint && npm test -- --run`. Confirm that the committed
  bundle in `lib/ruby_reactor/web/public/` matches a fresh `npm run build`.
- [ ] T075 Demo specs, locally:
  `cd demo_app && REDIS_URL=redis://localhost:6780/5 RAILS_ENV=test bundle exec rspec spec/reactors/{bulk_refund,contended_approval,dual_approval}_demo_reactor_spec.rb`,
  and `REDIS_URL=redis://localhost:6780/5 bin/rails demo:rollback_follow_ups`.
- [ ] T076 Docker acceptance (Constitution VI.4), using an isolated compose project because the
  container names are fixed:
  `docker compose -p rr_rollback_follow_ups -f docker-compose.yml -f <override with unique container_name and ports: !reset []> up -d --build demo-redis demo-sidekiq`,
  then `run --rm --no-deps demo-app bash -c "bin/rails db:prepare && bin/rails demo:rollback_follow_ups"`.
  Check the printed outcomes against quickstart §9, then tear the project down. Ask before
  touching another worktree's containers.
- [ ] T077 Walk through quickstart.md §1–§9 and tick each row. Fix any drift in the quickstart
  itself.
- [ ] T078 Fill in `specs/010-rollback-follow-ups/pr-description.md`: the summary per story, the
  migration notes (R-16), the regression proof from T018, the T002 and T072 counts, and the
  Docker run output.

---

## Dependencies & Execution Order

### Phase dependencies

```text
Phase 1 Setup ─▶ Phase 2A (T003–T008) ─┬─▶ US1 (Phase 3) ─▶ US2 (Phase 4)
                                       ├─▶ US6 (Phase 8)
                 Phase 2B (T009–T013) ─┴─▶ US3 (Phase 5) ─▶ US4 (Phase 6)
                                                    └────▶ US5 (Phase 7)
US7 (Phase 9): depends on Phase 1 only
Phase 10 Polish: after every story
```

### Story dependencies

- **US1**: Phase 2A only. It is the MVP.
- **US2**: US1, because T016's lock in `execute` is one half of the fix; T007 is the other.
- **US3**: Phase 2A and 2B.
- **US4**: US3, because it needs `continue` steps 1 and 3 from T024.
- **US5**: US3, because it extends T024 and T027.
- **US6**: Phase 2A (T008's reload). Independent of US3–US5.
- **US7**: independent of every other story. It can run in parallel from the start.

### Within each story

1. Specs first; they must fail.
2. Library code.
3. RSpec surface.
4. Demo: reactor, then rake task, then spec.
5. Documentation and CHANGELOG.

---

## Parallel Execution Examples

- **Phase 2**: T003, T004, T005 and T009 are separate spec files and can run in parallel. T010
  (storage) can run in parallel with T006 and T008. T007 and T013 both touch `worker.rb`, so run
  them in sequence.
- **After Phase 2**: these streams are independent:
  - US1 (T014–T017), then US2 (T018–T020);
  - US6 (T046–T055);
  - US7 (T056–T066).
- **US3**: T021, T022 and T023 (specs) together, then T028 (demo reactor) in parallel with T024 to
  T027.
- **US5**: T036, T037 and T038 together; T042 (demo reactor) in parallel with T039 to T041.
- **US6**: T046 and T047 together; T048 in parallel with T049.
- **US7**: T056 and T057 together; T063 in parallel with T058 to T062.
- **Polish**: T068, T069, T070 and T074 in parallel.

## Implementation Strategy

### MVP (User Story 1 only)

1. Phase 1, then Phase 2A.
2. Phase 3 (US1): the sweeper no longer re-runs live synchronous runs.
3. **Stop and validate**: quickstart §1. Ship as a PATCH if needed (no public API change).

### Incremental delivery

1. **US1 + US2** (ownership): one PR-sized increment.
2. **Phase 2B + US3**: a contended resume becomes a hand-off. This is the webhook fix and a MINOR
   API change, with a CHANGELOG migration note.
3. **US4 + US5**: claim semantics, with "already resumed" and concurrent interrupts.
4. **US6**: the cut-off compensate.
5. **US7**: `undo_all`, the only pure feature.
6. **Polish**: the Docker acceptance run and the PR description.

Each increment keeps the suite green and its docs current (Constitution, Development Workflow).
