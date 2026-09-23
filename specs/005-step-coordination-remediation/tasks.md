---
description: "Task list for Step Coordination Review Remediation"
---

# Tasks: Step Coordination Review Remediation

**Input**: Design documents from `specs/005-step-coordination-remediation/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md),
[data-model.md](./data-model.md), [contracts/public-api.md](./contracts/public-api.md),
[quickstart.md](./quickstart.md)

**Tests**: REQUIRED.
- Constitution III (test-first, real Redis) and FR-027 both require every repro to be written
  first and to be seen **failing on `ca963444`** before its fix.
- Tests use real Redis. There are no Redis or Sidekiq mocks.
- Worker parks are driven through `RubyReactor::Adapters::Sidekiq::Worker.new.perform(*job["args"])`,
  the pattern `demo_app/lib/tasks/demo_reactors.rake` uses. P4 uses the real Sidekiq worker
  (`spec/support/real_async_backend.rb`).

**Organization**: tasks are grouped by the user stories in spec.md.
- Story labels match spec numbering: US1 rollback, US2 parks, US3 ordering, US4 background step
  state, US5 attribution, US6 livelock docs, US7 regression layout.
- Phase order follows the plan's order of work. The three P1 stories are ordered to reduce
  risk: US1 → US3 → US2, with the riskiest last.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (a different file, and no dependency on an incomplete task)
- **[Story]**: the user story the task belongs to
- Paths are repository-relative. Research references (R-xx, D-xx) point into
  [research.md](./research.md).

## Path Conventions

- The library is in `lib/ruby_reactor/`, and specs are in `spec/` (RSpec, real Redis on :6780).
- New fixture reactors go in **new per-story files** under `spec/support/reactors/`. Both
  `spec/spec_helper.rb:56` and `spec/support/sidekiq_boot.rb:32` glob that directory, so the
  live Sidekiq worker sees them too. Per-story files keep the fixture tasks parallel.
- Every file under `spec/ruby_reactor/step_coordination/` is automatically tagged
  `:step_coordination`, which provides `step_coord_run_id` and `overlap_recorder`
  (`spec/support/step_coordination_helpers.rb`).

---

## Phase 1: Setup

**Purpose**: record a baseline, so FR-028 (no lost examples) and SC-011 (no *new* lint
offenses) can be checked at the end.

- [X] T001 Record the baseline in `specs/005-step-coordination-remediation/baseline.md`.
  1. Start the test Redis with `docker compose up -d redis-test`.
  2. On the current HEAD, run `bundle exec rspec` and record the total example and failure
     counts.
  3. For every file in `spec/ruby_reactor/step_coordination/`, run
     `bundle exec rspec <file> --dry-run` and record its example count. Record
     `review_fixes_spec.rb`, `review_fixes_round3_spec.rb` and `review_fixes_round4_spec.rb`
     separately.
  4. Run `bundle exec rubocop` and record the pre-existing offense in
     `spec/map/map_inline_execution_spec.rb:103` (`RSpec/MultipleMemoizedHelpers`).

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: the design record, which must exist before coding (FR-025), and the park-signal
error classes that US2 and US3 both depend on.

**⚠️ CRITICAL**: no user story work can begin until this phase is complete.

- [X] T002 Record the decisions in `specs/003-step-lock-declarations/research.md`.
  - Append the sections **D-F1**, **D-F3** and **D-A2**. Copy each one's Decision, Rationale
    and Alternatives from `specs/005-step-coordination-remediation/research.md` §2, and link
    back to it.
  - Amend **D4** ("Contention parks via the step-retry requeue path"). The park is now raised
    as `Error::StepContentionPark` and requeued by `Worker` or `Map::ElementExecutor` after
    every executor has parked its holds. The behavior (park and retry, a separate counter, a
    ceiling) is unchanged.
  - Amend the Open-risks row "Compensation stalls on a contended key" (line ~257). It should
    now say: waits up to `rollback_wait`, which defaults to the hold's `ttl` (60 s for a
    semaphore), then reports on `Failure#rollback_failures`. It never parks.
  - (FR-025, FR-026)
- [X] T003 [P] Amend **FR-026** in `specs/003-step-lock-declarations/spec.md` to read:
  "Compensation or undo that cannot take its key within its rollback wait (default: the
  declared hold's expiry) MUST be reported on the execution's failure (`rollback_failures`)
  rather than silently skipped. See 005." (FR-026)
- [X] T004 Create the park-signal hierarchy (data-model "Park Signal", R-01).
  - `lib/ruby_reactor/error/execution_parked.rb`: `class ExecutionParked < Base`. Its class
    comment states the contract: every rescue between the raise site and
    `Worker`/`ElementExecutor` either re-raises it untouched, or parks its own holds and then
    re-raises.
  - `lib/ruby_reactor/error/step_contention_park.rb`: `class StepContentionPark < ExecutionParked`.
    - `attr_reader :contended`.
    - `initialize(contended)` calls `super(contended.message)`.
    - `original` returns `contended.original`.
    - `retry_after_seconds` returns `contended.retry_after_seconds`.
    - These two delegations let `Worker.snooze_delay` and `Worker.hinted_retry?` work
      unchanged.
  - In `lib/ruby_reactor/error/async_result_pending.rb`, change the superclass from `Base` to
    `ExecutionParked`.
  - Confirm Zeitwerk loads them with
    `bundle exec ruby -Ilib -e 'require "ruby_reactor"; p RubyReactor::Error::StepContentionPark.ancestors.take(4)'`.

**Checkpoint**: the design record is written and the park signals exist. Story work can begin.

---

## Phase 3: User Story 1: An undo is not dropped because the key is busy (Priority: P1) 🎯 MVP

**Goal**: rollback re-takes a step's lock or semaphore with its own bounded `rollback_wait`,
which defaults to `ttl`, or 60 s for a semaphore. Every undo or compensation that does not
complete is listed on `Failure#rollback_failures` (F1, FR-001–FR-005).

**Independent Test**: [quickstart.md](./quickstart.md) R1. A synchronous reactor whose locked
`:charge` succeeds, then a later step holds the same key externally and fails.
- If the holder releases within `rollback_wait`, the undo ran.
- If it does not, `result.rollback_failures` names `:charge`, the key, and
  `:coordination_unavailable`.

### Tests for User Story 1 ⚠️ write first, and confirm they FAIL on `ca963444`

- [X] T005 [P] [US1] Create the fixtures in
  `spec/support/reactors/rollback_contention_reactors.rb`.
  - `RbcChargeStep`: a class step. `input :account_id`,
    `with_lock(ttl: 1) { |a| "rbc:acct:#{a[:account_id]}" }` (the default `wait: 0`). Its
    `undo` `RPUSH`es `"undo:#{account_id}"` onto Redis list `"rbc:log:#{run_id}"`.
  - `RbcShortRollbackChargeStep`: the same, but `with_lock(ttl: 5, rollback_wait: 0.2)`.
  - `RbcSemaphoreChargeStep`: `with_semaphore(limit: 1) { … }`, with no `rollback_wait`.
  - `RbcRaisingUndoStep`: its `undo` raises `"boom"`.
  - `RbcFailureUndoStep`: its `undo` returns `Failure("nope")`.
  - `RbcFailingCompensateStep`: it fails, and its `compensate` returns `Failure("comp-fail")`.
  - Synchronous reactors, each with inputs `run_id`, `account_id` and `hold_seconds`:
    - `RbcReactor`: `:charge` (`RbcChargeStep`), then `:contend`. The inline `:contend`
      acquires `RubyReactor::Lock.new(key, owner: "external", ttl: 10)`, starts a thread that
      releases it after `hold_seconds`, then raises.
    - `RbcShortWaitReactor`, `RbcSemaphoreReactor`, `RbcRaisingUndoReactor` and
      `RbcFailureUndoReactor`: variants of `RbcReactor` built on the step classes above.
    - `RbcCompensateReactor`: its first step succeeds with a recording undo, and its second is
      `RbcFailingCompensateStep`.
    - `RbcComposedParentReactor`: composes `RbcChildReactor` (which contains `RbcChargeStep`),
      then runs `:contend` on the child's key with `hold_seconds: 3` and `rollback_wait`
      exceeded. `RbcChildReactor` must use `RbcShortRollbackChargeStep` for this.
- [X] T006 [US1] Write `spec/ruby_reactor/step_coordination/rollback_under_contention_spec.rb`
  (R1 and variants). Each example asserts on `result`, a `RubyReactor::Failure`.
  1. `RbcReactor`, `hold_seconds: 0.5`: the undo ran (the list contains `undo:<id>`), and
     `result.rollback_failures == []`. The `ttl: 1` default outlasts the hold, where the
     forward `wait: 0` would not.
  2. `RbcShortWaitReactor`, `hold_seconds: 2`: the undo did not run, and
     `rollback_failures` includes
     `{ step: :charge, kind: :undo, key: "rbc:acct:<id>", reason: :coordination_unavailable }`.
  3. `RbcSemaphoreReactor`, `hold_seconds: 0.5`: the undo ran. The default is 60 s.
  4. `RbcRaisingUndoReactor`: an entry with `reason: :raised` and message `"boom"`.
  5. `RbcFailureUndoReactor`: an entry with `reason: :returned_failure`.
  6. `RbcCompensateReactor`: an entry with `kind: :compensate`, `reason: :returned_failure`.
  7. `RbcComposedParentReactor`: the child's `:charge` entry is flattened into the parent's
     list. There is no opaque entry for the compose step.
  8. `RubyReactor::Failure.new(result.to_h)` round-trips `rollback_failures`, with symbol
     `kind`, `reason` and `step`.

  Run the file and confirm 1–8 fail.

### Implementation for User Story 1

- [X] T007 [P] [US1] In `lib/ruby_reactor/dsl/lockable.rb`:
  - Add `rollback_wait: nil` to `with_lock` and `with_semaphore`, and store it in the config
    hash.
  - When it is not nil, raise `ArgumentError` unless it is `Numeric` and `>= 0`.
  - Document it in the YARD comments: step-only, ignored on reactors, defaults to `ttl`, or
    60 s for a semaphore.
  - Confirm `lib/ruby_reactor/dsl/step_builder.rb` (which includes
    `Lockable::ClassMethods`) exposes it to inline steps with no change.
- [X] T008 [P] [US1] Add `rollback_failures` to `RubyReactor::Failure` in `lib/ruby_reactor.rb`
  (data-model "Rollback Failure Entry").
  - Add an `attr_reader :rollback_failures` and an `initialize` keyword
    `rollback_failures: nil`, stored as `Array(rollback_failures)`.
  - Include it in `to_h`.
  - In `extract_attributes_from_hash`, read it back with each entry's keys symbolized and
    `step`, `kind` and `reason` converted to Symbols.
  - Add a `rollback_failures:` pass-through keyword to
    `lib/ruby_reactor/max_retries_exhausted_failure.rb#initialize`.
- [X] T009 [US1] In `lib/ruby_reactor/executor/step_coordination.rb` (R-08, D-F1):
  - Add `DEFAULT_ROLLBACK_WAIT = 60`.
  - `rollback_with_lock` uses `wait: config[:rollback_wait] || config[:ttl]`.
  - `rollback_with_semaphore` uses `config[:rollback_wait] || DEFAULT_ROLLBACK_WAIT`.
  - `rollback_failure(primitive, key, error)` returns
    `RubyReactor::Failure(Contended.new(primitive:, key:, step_name:, reactor_name: reactor_label, original: error, message: "could not re-acquire #{primitive} '#{key}' for rollback of :#{step_name} within #{wait}s: #{error.message}"), retryable: false, step_name:)`.
    Pass `wait` in. In the `KeyError` branch the key stays `nil`.
  - Rewrite the `around_rollback` comment: it now uses `rollback_wait`, not the configured
    forward `wait:`.
- [X] T010 [US1] Collect failures in `lib/ruby_reactor/executor/compensation_manager.rb`.
  - Add `attr_reader :rollback_failures`, initialized to `[]`.
  - Add a private `record_rollback_failure(step_name, kind, outcome)`:
    - a `RubyReactor::Failure` with a non-empty `rollback_failures` concatenates that list
      (the nested compose case);
    - a `Failure` whose `error` is a `StepCoordination::Contended` gives
      `reason: :coordination_unavailable` and `key: error.key`;
    - any other `Failure` gives `reason: :returned_failure`;
    - an `Exception` gives `reason: :raised`;
    - every entry sets `message` (`error.message` or `to_s`).
  - Call it from `undo_step` (the Failure-result branch and the `rescue StandardError` branch,
    with `kind: :undo`) and from `compensate_step` (the Failure-result branch, with
    `kind: :compensate`, and before re-raising in its `rescue`).
- [X] T011 [US1] Attach the list to the final failure in
  `lib/ruby_reactor/executor/result_handler.rb` (one choke point, R-08).
  - In `handle_execution_error`, bind the case result to `failure`, then run
    `failure.rollback_failures.concat(@compensation_manager.rollback_failures) if failure.is_a?(RubyReactor::Failure)`
    before returning.
  - In `handle_failure` and `handle_retries_exhausted`, **before** calling
    `@compensation_manager.handle_step_failure`, run
    `@compensation_manager.rollback_failures.concat(result.rollback_failures) if result.respond_to?(:rollback_failures)`,
    so a composed child's entries come first.
  - In `lib/ruby_reactor/executor/retry_manager.rb#handle_non_retryable_failure`, pass
    `rollback_failures: result.rollback_failures` into `MaxRetriesExhaustedFailure.new`.
- [X] T012 [US1] In `lib/ruby_reactor/step/compose_step.rb#compensate` (also aliased as
  `undo`): after `executor.undo_all`, return
  `RubyReactor::Failure("composed :#{step_name} rollback incomplete", rollback_failures: executor.compensation_manager.rollback_failures)`
  when that list is non-empty. Otherwise return `Success()`.
- [X] T013 [US1] Run `bundle exec rspec spec/ruby_reactor/step_coordination/rollback_under_contention_spec.rb spec/ruby_reactor/step_coordination/rollback_spec.rb spec/ruby_reactor/skipped_rollback_spec.rb spec/ruby_reactor/interrupt_undo_spec.rb spec/ruby_reactor/failure_reporting_spec.rb`
  and make it green. An existing spec that matched the old bare-string rollback message may
  change only its message expectation (FR-029).
- [X] T014 [US1] Update the "### Step Rollback" section (~:793-803) of
  `documentation/locks_and_semaphores.md`.
  - Replace "uses the *configured* `wait:` directly" with `rollback_wait:`: what it defaults
    to (`ttl`, or 60 s for a semaphore), that it blocks the worker thread while it waits, and
    that it never parks.
  - Document `Failure#rollback_failures`, with the example from `contracts/public-api.md` §2.
  - Correct `:802`: an undo that could not re-acquire yields a `type: :undo` trace entry plus
    the `on_failed_undo` hook, and an undo that raised yields `type: :undo_failure`. Neither
    is a ":failed_undo trace entry".
- [X] T015 [US1] In `README.md`: add `rollback_wait:` wherever step `with_lock`/`with_semaphore`
  options are listed, and add `Failure#rollback_failures` to the section describing
  `RubyReactor::Failure`'s readers.

### Demo for User Story 1 (Constitution VI, FR-030)

- [X] T016 [P] [US1] Add a `have_rollback_failure(step_name)` matcher in
  `lib/ruby_reactor/rspec/matchers.rb`.
  - Optional chains: `.for_key(key)` and `.because(reason)`.
  - It resolves `actual` the same way `be_failure` does (a `Failure`, or a `TestSubject`'s
    result) and matches against `rollback_failures`.
  - Its failure message lists the actual entries.
  - Add examples in the new file `spec/ruby_reactor/rspec/rollback_failure_matcher_spec.rb`:
    match, no match, `for_key` and `because`.
- [X] T017 [US1] Add a rollback-under-contention path to
  `demo_app/app/reactors/step_lock_demo_reactor.rb`.
  - Add an input `contend_on_rollback` (Boolean) and an input `rollback_hold_seconds`.
  - When `contend_on_rollback` is set, a class step `StepLockRollbackContenderStep` after
    `:charge` holds `"demo:acct:#{account_id}"` as owner `"demo-external"`, releases it from a
    thread after `rollback_hold_seconds`, then fails.
  - Add a second locked step class, `StepLockShortRollbackChargeStep`, with
    `with_lock(wait: 2, rollback_wait: 0.2)`, used when an input `short_rollback_wait` is set.
  - If the inputs would muddle the existing reactor, create
    `demo_app/app/reactors/step_lock_rollback_demo_reactor.rb` (`StepLockRollbackDemoReactor`)
    instead. That is one reactor per file.
- [X] T018 [US1] In the `demo:step_lock` task in `demo_app/lib/tasks/demo_reactors.rake`, add
  two scenarios:
  - "=== 4. Rollback under contention": the hold is 0.5 s, the undo waits and runs, and it
    prints the undo log entry, with ✅/❌.
  - "=== 5. Rollback wait exceeded": `short_rollback_wait: true` and a 2 s hold. It prints
    `result.rollback_failures`, with ✅ when it names `:charge` and `:coordination_unavailable`.
- [X] T019 [US1] In `demo_app/spec/reactors/step_lock_demo_reactor_spec.rb` (or the sibling
  spec for T017's alternative), add `describe "rollback under contention"`. Use only the
  shipped surface: `test_reactor`, `be_failure`,
  `have_rollback_failure(:charge).because(:coordination_unavailable)`, and
  `not_to have_rollback_failure(:charge)` for the within-wait case.

**Checkpoint**: US1 is complete. R1 is green, and the public `rollback_wait:` and
`rollback_failures` are documented and demoed.

---

## Phase 4: User Story 3: Step-level strict ordering follows the reactor-level rules (Priority: P1)

**Goal**: one exhaustive gate classifier for both levels.
- The step-level stale batch is skipped (F7).
- The heartbeat always stops (F8).
- A synchronous out-of-turn arrival hands its position back without poisoning the chain (F3).
- Covers FR-010–FR-016.

**Independent Test**: [quickstart.md](./quickstart.md) R3, P1, P2 and P3. E1 holds its turn,
and E2 arrives synchronously out of turn and fails. E3, arriving after E1, runs the step body.

### Tests for User Story 3 ⚠️ write first, and confirm they FAIL on `ca963444`

- [X] T020 [P] [US3] Create the fixtures in
  `spec/support/reactors/ordering_parity_reactors.rb`.
  - `OspStrictStep`: a class step with `input :run_id` and `input :sleep_seconds` (default 0),
    and `with_ordered_lock(strict: true, poison_pill_timeout: 30) { |a| "osp:#{a[:run_id]}" }`.
    Its body `RPUSH`es an execution tag onto `"osp:log:#{run_id}"`, sleeps `sleep_seconds`,
    and returns `Success(tag)`.
  - `OspSyncReactor`: synchronous, running `OspStrictStep` as `:ordered`, and
    `returns :ordered`.
  - `OspRetryStep`: the same ordered lock, `retries max_attempts: 2` with a near-zero backoff,
    and a body that fails retryably on its first attempt (tracked by a Redis counter).
  - `OspRetryReactor`: runs `OspRetryStep`.
  - `OspAbortStep`: raises `NoMemoryError` when `input :abort` is true.
  - A reactor-level counterpart for parity: `OspReactorLevel`, with `background all: true` and
    reactor `with_ordered_lock(strict: true) { |i| "osp:r:#{i[:run_id]}" }`.
- [X] T021 [US3] Write `spec/ruby_reactor/step_coordination/ordering_parity_spec.rb`.
  - **R3**:
    1. E1 runs `OspSyncReactor` in a `Thread` with `sleep_seconds: 1`.
    2. After E1 enters (poll the log), E2 runs synchronously and is expected to be a Failure
       with a contention error.
    3. After E1's thread joins, E3 runs. Expect success, a non-nil value, E3's tag in the log,
       and `"osp:<run_id>"` never chain-failed (E3 was not skipped).
  - **P1**: give `OspRetryReactor`'s step a position, fail once (a retry is pending, and the
    stash is kept), drain the batch past it with `RubyReactor::OrderedLock.skip!`, and start a
    new batch on the same key with `OrderedLock.assign`. Let the retry run. Expect
    `be_skipped` with reason `:ordered_lock_stale_batch`, and the body count unchanged.
  - **P2**: wrap `OrderedLockSupport.start_heartbeat` with `and_wrap_original` to capture the
    returned `Heartbeat`, then run `OspAbortStep` with `abort: true` and
    `expect { … }.to raise_error(NoMemoryError)`. Expect the thread in the captured
    heartbeat's `@thread` to be `!alive?` after a short join, and
    `have_ordered_lock_last_completed` unchanged (no advance, R-07 `:abandoned`).
  - **P3 parity table**: for each of `go`, `wait`, `skip_chain`, `stale` and `drained`, build
    the real Redis state with `OrderedLock.assign`, `advance!`, `skip!` or `reset!`, never
    stubbing `OrderedLock`. Assert the reactor-level outcome and the step-level outcome from
    the data-model table.

  Confirm R3, P1 and P2 fail.

### Implementation for User Story 3

- [X] T022 [US3] Add the classifier in `lib/ruby_reactor/executor/ordered_lock_support.rb`
  (R-06). Add `def self.gate(info, fresh:)`:
  - It builds `OrderedLock.new(info[:key], nonce:, epoch:, poison_pill_timeout:, strict:)` and
    calls `check!`.
  - It maps the result exhaustively: `:go` → `:go`; `:skip_chain_failed` →
    `fresh ? :skip_chain : :go`; `:stale_batch` → `:stale`; `:drained_go` → `:drained`; `else`
    raises `ArgumentError`. `WaitError` propagates.
  - Rewrite `enter_ordered_lock_scope` to call it (when there is no info, the outcome is
    `:go`):
    - `@ordered_lock_stale_batch = outcome == :stale`
    - `@ordered_lock_chain_skip = outcome == :skip_chain`
    - `@ordered_lock_drained_replay = outcome == :drained && stored_status_terminal?`
  - Remove `check_ordered_lock_gate` if `grep -rn check_ordered_lock_gate lib spec` finds no
    other caller.
  - Run `bundle exec rspec spec/ruby_reactor/integration/ordered_lock_spec.rb spec/ruby_reactor/storage/redis_ordered_locking_spec.rb`.
    It must stay green: there is no reactor-level behavior change.
- [X] T023 [US3] Rewrite the step gate in `lib/ruby_reactor/executor/step_coordination.rb`
  (R-06, D-F3).
  - `ordered_lock_gate` calls `OrderedLockSupport.gate(info, fresh: true)`, wrapping
    `WaitError` into `Contended` exactly as `check_ordered_lock!` does today. Remove or fold
    `check_ordered_lock!`.
  - `case outcome`:
    - `:go`, `:drained`: `with_active_ordered_key { run_under_ordered_lock(info, &block) }`
    - `:skip_chain`: `advance_with_retry(info, failed: false)`, `delete_ordered_lock_stash`,
      `Skipped(reason: :ordered_lock_chain_failed)`
    - `:stale`: `delete_ordered_lock_stash`, then `Skipped(nil, reason: :ordered_lock_stale_batch, step_name:)`,
      with **no** advance (F7)
  - In `gate_ordered_lock`'s `rescue Contended` (out of turn), `unless parking?`, use
    `advance_with_retry(info, failed: **false**)` (D-F3) and delete the stash. Update the
    comment.
- [X] T024 [US3] Rewrite `run_under_ordered_lock` in
  `lib/ruby_reactor/executor/step_coordination.rb` (R-07, F8).
  - Keep a single `outcome = :abandoned`.
  - After `yield`, set `outcome` to `:retry_pending` when `retry_pending?(result)`, otherwise
    to `chain_failed?(result) ? :failed : :succeeded`.
  - `rescue Contended` sets `outcome = parking? ? :parked : :failed`, then re-raises.
  - `rescue Error::ExecutionParked` sets `outcome = :parked`, then re-raises.
  - `rescue StandardError` sets `outcome = :failed`, then re-raises.
  - `ensure` runs `heartbeat.stop` then `finish_position(info, outcome)`.
  - Add a private `finish_position`:
    - `:succeeded`: advance with `failed: false`, and delete the stash;
    - `:failed`: advance with `failed: true`, and delete the stash;
    - `:parked`, `:retry_pending` and `:abandoned`: keep.
  - Add a comment on `:abandoned` explaining why it does not advance: `Sidekiq::Shutdown`
    redelivers the job, and the poison pill releases the position.
- [X] T025 [US3] Update the step `with_ordered_lock` section of
  `documentation/locks_and_semaphores.md`.
  - Add a "**Use only on `background all: true` reactors**" callout, adapted from `:494`/`:665`:
    a synchronous out-of-turn arrival fails with a contention error and hands its position
    back, and later arrivals then proceed. A position that reached the head and then failed
    still skips its strict successors.
  - Document `Skipped(reason: :ordered_lock_stale_batch)` for a step whose batch expired
    before its retry.
- [X] T026 [US3] Run `bundle exec rspec spec/ruby_reactor/step_coordination/ordering_parity_spec.rb spec/ruby_reactor/step_coordination/primitives_spec.rb spec/ruby_reactor/step_coordination/review_fixes_spec.rb spec/ruby_reactor/integration/ordered_lock_spec.rb`
  and make it green. `review_fixes_spec.rb:310` (synchronous lock contention *after* the gate)
  must still drain the key: that position was at the head, so it keeps `failed: true`.

**Checkpoint**: US3 is complete. Both levels share one classifier, and R3, P1, P2 and P3 are
green.

---

## Phase 5: User Story 2: A park at any depth keeps outer holds and charges quotas once (Priority: P1)

**Goal**: one exception-based park mechanism.
- Every executor on the stack parks its own holds.
- Quotas are charged once, through an explicit admission marker.
- A background-result wait inside a composed child parks and no longer fails the parent (F2,
  F10).
- Covers FR-006–FR-009.

**Independent Test**: [quickstart.md](./quickstart.md) R2, R4 and R6. A background parent with
a lock and a rate limit composes a child whose first step is locked. Hold the child's key,
perform once (it parks), release, and perform again. The parent's lock stayed held, and the
rate count is 1.

### Tests for User Story 2 ⚠️ write first, and confirm they FAIL on `ca963444`

- [X] T027 [P] [US2] Create the fixtures in `spec/support/reactors/park_reactors.rb`.
  - `ParkChildStep`: a class step with `with_lock { |a| "park:acct:#{a[:account_id]}" }`.
  - `ParkChildReactor`: its first step is `:charge` (`ParkChildStep`).
  - `ParkRateParentReactor`: `background all: true`,
    `with_rate_limit(limits: { minute: 100 }) { |i| "park:rl:#{i[:run_id]}" }`, and
    `compose :child, ParkChildReactor` as its **first** step.
  - `ParkLockParentReactor`: `background all: true`,
    `with_lock { |i| "park:parent:#{i[:run_id]}" }`, and the same compose.
  - `ParkMiddleReactor`: `with_lock { |i| "park:middle:#{i[:run_id]}" }`, its own rate limit,
    and `compose :child, ParkChildReactor`.
  - `ParkGrandParentReactor`: `background all: true`, `compose :middle, ParkMiddleReactor`.
  - `ParkAsyncReaderChild`: `with_lock { |i| "park:reader:#{i[:run_id]}" }`, an `async_step :fetch`,
    and a step reading `result(:fetch)`.
  - `ParkAsyncReaderParent`: `background all: true`, `compose :child, ParkAsyncReaderChild`,
    `returns :child`.
  - A map fixture, `ParkMapReactor`, whose element reactor's first step is `ParkChildStep`.
- [X] T028 [US2] Write `spec/ruby_reactor/step_coordination/park_spec.rb`. Use
  `Sidekiq::Testing.fake!`, and drive each job once with
  `RubyReactor::Adapters::Sidekiq::Worker.new.perform(*job["args"])`.
  - **R2**: hold `"park:acct:<id>"` externally, perform once (no failure, one job
    re-enqueued), release, perform again (completed). Expect
    `"park:rl:<run_id>"` to `have_rate_limit_count(1)`, and the no-contention control to be
    1 as well.
  - **R4**: `ParkLockParentReactor`. After the first perform, `"park:parent:<run_id>"`
    `be_locked`. After the second, it is not locked. A recording middleware sees exactly one
    `:lock_acquired` for the parent key.
  - **Depth 2**: `ParkGrandParentReactor`. Between performs, the middle lock is held, and the
    middle rate count is 1 after completion.
  - **US2-3**: the park is in the first step of both the root and the child (covered by R2's
    fixture).
  - **US2-5**: expire the parent lock between performs (a short `ttl` and a sleep). The
    redelivery re-acquires it, and the rate count is still 1.
  - **US2-6**: with `lock_snooze_max_attempts = 1`, perform twice while contended. The result
    is a terminal Failure, and the parent key is not locked.
  - **US2-7**: a `ParkMapReactor` element parks, and completes after release.
  - **R6**: `ParkAsyncReaderParent`. Perform once. It snoozes (the context status is not
    `failed`, and a job is re-enqueued), and `"park:reader:<run_id>"` `be_locked` (US2-4).
    Drain the StepWorker job, perform again, and expect completion with the child's value.
  - **Events**: exactly one `:snooze_step` for the parked step, and no `:failed_step`.

  Confirm that R2, R4, the depth-2 case, US2-4, R6 and the events examples fail.

### Implementation for User Story 2

The steps follow the rescue-site order in research R-01.

- [X] T029 [US2] In `lib/ruby_reactor/executor/step_executor.rb#safe_execute_step_sync`, add
  `rescue Error::ExecutionParked; raise` before `rescue StandardError => e`. This is the F10
  fix: park signals leave a composed step untouched.
- [X] T030 [US2] In the `rescue Exception => e` of
  `lib/ruby_reactor/executor/step_executor.rb#execute_step`, when
  `e.is_a?(Error::ExecutionParked)`, emit
  `@middlewares.on(:snooze_step, step_config.name, e, @context)` in place of `:failed_step`,
  then re-raise (R-04).
- [X] T031 [US2] Rewrite `handle_contention` in `lib/ruby_reactor/executor/step_executor.rb`
  (R-01, R-05).
  - Keep the `current_step` pin, the trace entry, the `:step_contention` marker and the log
    line.
  - Then give back the retry attempt
    (`@context.retry_context.decrement_attempt_for_step(step_config.name)`) and increment the
    contention counter.
  - When `lock_snooze_max_attempts` is exceeded, and the original is not an
    `OrderedLock::WaitError`, call `StepCoordination.discard_parked_state!(@context)` and
    return the terminal `Failure(Contended.new(... "gave up on … after N contention attempts"))`.
    Move that verbatim from `retry_manager.rb:47-70`.
  - Otherwise `raise Error::StepContentionPark.new(contended)`.
  - Remove `@on_contention_park` from `initialize`.
- [X] T032 [US2] In `lib/ruby_reactor/executor/retry_manager.rb`, delete `park_for_contention`
  and fix the `execute_with_retry` and `requeue_job` comments that mention contention parks.
- [X] T033 [US2] In `lib/ruby_reactor/executor/step_coordination.rb#around_run`, add
  `rescue Error::ExecutionParked; raise` before `rescue StandardError`. A park is not terminal,
  so it must not clear the contention state.
- [X] T034 [US2] Add the admission marker in `lib/ruby_reactor/context.rb` and
  `lib/ruby_reactor/executor.rb` (R-03, data-model "Execution Admission").
  - Add `Context#admitted?`, which reads `private_data[:admitted]` or `["admitted"]`, and
    `Context#admit!`.
  - `Executor#execute` calls `@context.admit!` after the post-lock `check_period_gate`.
  - `resume_execution` calls `@context.admit!` after the post-lock period re-check, when
    `first_run`.
  - `first_execution?` becomes
    `!@context.admitted? && @context.current_step.nil? && @context.intermediate_results.empty?`.
  - `fresh_ordered_lock_start?` in `lib/ruby_reactor/executor/ordered_lock_support.rb` uses
    the same predicate.
- [X] T035 [US2] Park at every level in `lib/ruby_reactor/executor.rb` (D-A2).
  - Remove `on_contention_park:` from the `StepExecutor` managers, along with its comment.
  - In `execute`, replace `rescue Error::AsyncResultPending` with
    `rescue Error::ExecutionParked`. That branch calls
    `park_held_primitives! if @context.inline_async_execution`, sets `@contention_snooze`, and
    re-raises. The `ensure` becomes `release_locks unless @parked`.
  - In `resume_execution`, `rescue Error::ExecutionParked => e` keeps today's body.
  - Rewrite both comments: every level parks, and a synchronous caller never sees a park
    signal.
- [X] T036 [US2] In `lib/ruby_reactor/step/compose_step.rb#execute_child_reactor`, call
  `executor.resume_execution` when
  `composed_data && (child_context.admitted? || child_context.current_step)`, and
  `executor.execute` otherwise (R-02).
- [X] T037 [US2] In `lib/ruby_reactor/worker.rb#perform`, replace
  `RubyReactor::Error::AsyncResultPending` in the snooze rescue list with
  `RubyReactor::Error::ExecutionParked`. In `handle_snooze`, the `capped` test excludes
  `Error::ExecutionParked`. Add a comment: the contention ceiling is enforced at the raise
  site with the per-step counter.
- [X] T038 [US2] In `lib/ruby_reactor/map/element_executor.rb#perform_element`, wrap the
  executor call in `begin … rescue Error::StepContentionPark => e`.
  - The handler runs `context.middlewares&.on(:before_async_enqueue, context)`, then calls
    `RubyReactor.configuration.async_router.perform_map_element_in(Worker.snooze_delay(RubyReactor.configuration, e), …)`,
    with the same keyword arguments as `retry_manager.rb:135-149` and
    `serialized_context: ContextSerializer.serialize(context)`.
  - Then `return`. Keep the `RetryQueuedResult` early return for failure retries.
- [X] T039 [P] [US2] Add `on_snooze_step(step_name, error, _context)` to
  `lib/ruby_reactor/open_telemetry.rb`.
  - Detach the step token, delete `@retry_errors[step_name]`, and pop the span.
  - Set `step.status = "parked"` and `step.park_reason = error.class.name`, with status OK,
    then `span.finish`.
- [X] T040 [US2] Update the specs that asserted the old park *mechanism* (R-12, FR-029).
  - `spec/ruby_reactor/step_coordination/observability_spec.rb:115-158` (`run_parked`):
    expect `raise_error(RubyReactor::Error::StepContentionPark)`. Keep the log-line, waiting
    and no-`:failed_step` assertions, and add `:snooze_step`.
  - `spec/ruby_reactor/step_coordination/primitives_spec.rb:87,286,291`.
  - `spec/ruby_reactor/step_coordination/review_fixes_round3_spec.rb:244-276`: the ceiling
    now goes through `handle_contention`. Keep "hands back the reactor-level hold".
  - The comment at `spec/ruby_reactor/step_coordination/contention_spec.rb:138`.
  - Run `grep -rn "on_contention_park\|park_for_contention" spec lib`, which must print
    nothing. Check the contention-park expectations in
    `spec/ruby_reactor/telemetry_spec.rb:437`.
- [X] T041 [US2] Audit the park path. Run
  `grep -n "rescue StandardError\|rescue Exception\|rescue => " lib/ruby_reactor/executor.rb lib/ruby_reactor/executor/*.rb lib/ruby_reactor/step.rb lib/ruby_reactor/step/*.rb lib/ruby_reactor/template/*.rb`.
  Every hit between argument resolution or a step body and `Worker` must re-raise
  `Error::ExecutionParked` untouched, park and then re-raise, or be shown unreachable. Record
  the result as an "Audited <date>: <n> sites" line under the R-01 table in
  `specs/005-step-coordination-remediation/research.md`.
- [X] T042 [US2] Documentation.
  - In the "### Step Contention" section (:769-780) of
    `documentation/locks_and_semaphores.md`:
    - a park at any nesting depth keeps every level's own lock and semaphore, and re-adopts
      them;
    - quotas are charged once;
    - a background-result wait inside a composed child parks.
  - In `documentation/middlewares.md`, document the new `on_snooze_step(step_name, error, context)`:
    when it fires, and that a park never emits `:failed_step`.
- [X] T043 [US2] Run `bundle exec rspec spec/ruby_reactor/step_coordination spec/compose_spec.rb spec/ruby_reactor/parked_wait_spec.rb spec/ruby_reactor/dsl/async_reactor_spec.rb spec/ruby_reactor/map spec/ruby_reactor/telemetry_spec.rb`,
  then the full `bundle exec rspec`, and make both green. Rerun
  `spec/ruby_reactor/dsl/async_reactor_spec.rb` alone before debugging a failure in it: it is
  a known load flake.

**Checkpoint**: US2 is complete. R2, R4, R6 and the depth-2 case are green, and there is one
park mechanism.

---

## Phase 6: User Story 4: A background step's park state does not clobber its parent (Priority: P2)

**Goal**: an `async_step`'s park state (its ordering position and its waiting marker) lives on
its own Step Result Record. The step worker never writes the parent's root blob on a park (F5,
FR-017–FR-019).

**Independent Test**: [quickstart.md](./quickstart.md) P4. Park an ordered `async_step` while
the parent saves newer progress. The step keeps its nonce, the parent's progress survives, and
the dashboard shows the step as waiting.

### Tests for User Story 4 ⚠️ write first, and confirm they FAIL on `ca963444`

- [X] T044 [P] [US4] Create the fixtures in `spec/support/reactors/async_step_park_reactors.rb`.
  - `AspOrderedStep`: a class step with
    `with_ordered_lock { |a| "asp:seq:#{a[:run_id]}" }` and
    `with_lock { |a| "asp:lock:#{a[:run_id]}" }`. Its body records to `"asp:log:#{run_id}"`.
  - `AspReactor`: `background all: true`, with `async_step :ordered` (`AspOrderedStep`) and a
    same-process sibling step `:progress` that records completion.
- [X] T045 [US4] Add a `describe "async_step park state (US4)"` block to
  `spec/ruby_reactor/step_coordination/park_spec.rb`. This is sequential after T028, in the
  same file. Use the real Sidekiq worker from `spec/support/real_async_backend.rb`.
  - Hold `"asp:lock:<run_id>"` externally and let the unit park.
  - Read the stored root blob, write a marker into its `private_data` through
    `storage.store_context` (a newer parent checkpoint), and wait one park cycle.
  - Expect:
    - the marker survives (the step worker did not overwrite the root);
    - the step's result record has `ordered_lock` and `waiting`;
    - `RubyReactor::Web::CoordinationSerializer.build(...)` reports `waiting` for `:ordered`;
    - after release and a drain, the step completes with its **original** nonce
      (`have_ordered_lock_last_completed` equals the nonce recorded at the first park).

  Confirm it fails.

### Implementation for User Story 4

- [X] T046 [US4] Change `lib/ruby_reactor/step_worker.rb` (R-09).
  - `handle_contention` passes `contended` to `mark_record_parked`.
  - `mark_record_parked(context, delay, attempt, contended)` also sets:
    - `record["ordered_lock"]` to the step's entry from
      `context.private_data[:step_ordered_locks]` (a string or symbol key of
      `@step_name.to_s`), when present;
    - `record["waiting"] = { "step" => @step_name, "primitive" => contended.primitive, "key" => contended.key, "attempts" => attempt }`.
  - `record_contention` keeps only the structured log line. Delete the trace append, the
    `private_data[:step_contention]` write and **`save_root`**.
- [X] T047 [US4] In `lib/ruby_reactor/step_worker.rb#load_step_context`, after `found` is
  resolved, read
  `storage.retrieve_step_result(@step_context_id, @step_name, step_result_namespace(found))`.
  When `record["ordered_lock"]` is present, set
  `(found.private_data[:step_ordered_locks] ||= {})[@step_name.to_s] = record["ordered_lock"].transform_keys(&:to_sym)`.
- [X] T048 [US4] In `lib/ruby_reactor/web/coordination_serializer.rb`, for steps whose
  `step_config.async_dispatch == :step`, derive `waiting` from the step result record's
  `waiting` field.
  - Read it with `adapter.retrieve_step_result(context_id, name, RubyReactor.reactor_storage_name(reactor_class))`
    and normalize it with `normalize_waiting`.
  - Keep `private_data[:step_contention]` for same-process steps.
- [X] T049 [US4] Update the existing specs that asserted async_step park evidence in the
  parent's trace or `private_data`. Find them with
  `grep -rn "contention_park\|step_contention" spec/ruby_reactor | grep -i async`, and check
  `spec/ruby_reactor/step_coordination/review_fixes_spec.rb:329-356`. Assert against the
  record, not the root blob.
- [X] T050 [US4] Document in `documentation/locks_and_semaphores.md` (the `async_step`
  contention note under Step Contention) that a parked `async_step` keeps its park state on
  its Step Result Record, with the `ruby_reactor.async_step.parked` log line, and that the
  parent trace has no `contention_park` entry for it.
- [X] T051 [US4] Run `bundle exec rspec spec/ruby_reactor/step_coordination/park_spec.rb spec/ruby_reactor/step_sweeper_spec.rb spec/ruby_reactor/step_contract_async_spec.rb`
  and `grep -rln async_step spec/ruby_reactor | xargs bundle exec rspec`, and make them green.

**Checkpoint**: US4 is complete. P4 is green, and the step worker never writes the root blob on
a park.

---

## Phase 7: User Story 5: Instrumentation attributes coordination to the right step (Priority: P2)

**Goal**: `coordinating_step` is documented as the attribution. A directly invoked step class
names itself (F4, F9, FR-020–FR-022).

**Independent Test**: [quickstart.md](./quickstart.md) R5 and P5. Reactor-level events have
`coordinating_step == nil` across a park and a redelivery. A direct call names the invoked
class.

### Tests for User Story 5 ⚠️ write first. P5 must FAIL on `ca963444`; R5 guards the docs claim.

- [X] T052 [P] [US5] Create the fixtures in `spec/support/reactors/attribution_reactors.rb`.
  - `AttrChargeStep`: a class step with `with_lock { |a| "attr:s:#{a[:account_id]}" }`.
  - `AttrReactor`: `background all: true`, reactor `with_lock { |i| "attr:r:#{i[:run_id]}" }`,
    and `:charge` (`AttrChargeStep`).
  - `AttrDirectOuterReactor`: a synchronous reactor whose step `:outer` body calls
    `AttrChargeStep.run({ account_id: args[:account_id] }, context)`.
- [X] T053 [US5] Write `spec/ruby_reactor/step_coordination/attribution_spec.rb`.
  - **R5**: a recording middleware captures `[event, key, context.coordinating_step]`. Hold
    `"attr:s:<id>"`, perform once (it parks), release, and perform again. Every event on
    `"attr:r:<run_id>"` has `coordinating_step == nil`, and every event on
    `"attr:s:<id>"` names `:charge`.
  - **P5**: hold `"attr:s:<id>"` externally and run `AttrDirectOuterReactor`. The failure
    message and the captured `:lock_failed` `coordinating_step` both name `AttrChargeStep`,
    not `:outer`.

  Confirm P5 fails.

### Implementation for User Story 5

- [X] T054 [US5] In `lib/ruby_reactor/executor/step_coordination.rb#step_name`, return
  `step_config.name` when `@direct`, before the `context.current_step` fallback (F9, R-10).
  Update the comment.
- [X] T055 [P] [US5] Docs only, so this can ship first.
  - In `documentation/middlewares.md:126-140`, replace `context.current_step` with
    `context.coordinating_step` in the prose and in the `on_lock_acquired` example, and add
    one sentence saying `current_step` is the resume cursor and is not for attribution.
  - In `documentation/locks_and_semaphores.md:866`, make the same replacement.
- [X] T056 [US5] Run `bundle exec rspec spec/ruby_reactor/step_coordination/attribution_spec.rb spec/ruby_reactor/step_coordination/observability_spec.rb spec/ruby_reactor/step_coordination/single_site_spec.rb`
  and make it green.

**Checkpoint**: US5 is complete.

---

## Phase 8: User Story 6: Authors are warned about cross-level livelock (Priority: P3)

**Goal**: guidance on keeping one key order across the reactor and step levels (F6,
FR-023, FR-024). This is docs only.

**Independent Test**: read the Step Contention section. It states that a step park keeps the
workflow's holds, and it gives the nesting-order rule with the A→B / B→A example.

- [X] T057 [US6] Add a "#### Nest keys in one order across levels" subsection to the
  "### Step Contention" section of `documentation/locks_and_semaphores.md`.
  - A step park keeps the reactor's own lock and semaphore, which is intended.
  - Reactor X (reactor lock A, step lock B) against reactor Y (reactor lock B, step lock A)
    wait on each other. They give up after about `lock_snooze_max_attempts` (default 20)
    snoozes, and wait forever with `:infinity`.
  - Rule: pick one global order for keys and nest in that order at every level.
  - Include a short, correct and incorrect code pair using class-based steps (per the
    constitution).

**Checkpoint**: US6 is complete.

---

## Phase 9: User Story 7: Regression coverage is organized by behavior (Priority: P3)

**Goal**: no spec file named after a review round. Every finding F1–F10 maps to a
behavior-named test, and no example is lost (FR-027, FR-028, SC-010).

**Independent Test**: `ls spec/ruby_reactor/step_coordination | grep review_fixes` prints
nothing, and the example count equals the baseline plus the new examples.

- [X] T058 [US7] Fold `spec/ruby_reactor/step_coordination/review_fixes_spec.rb` into the
  behavior files.
  - Move its fixture classes (lines 1–216) into
    `spec/support/reactors/step_coordination_reactors.rb`, or into the per-behavior fixture
    files. Keep the class names.
  - Move the describes:
    - direct invocation and serializer → `observability_spec.rb`;
    - synchronous contention and async_step park versus the sweeper → `park_spec.rb`;
    - ordered lock (`:310`, `:389`) → `ordering_parity_spec.rb`;
    - rollback of an inline step and the deadlock-guard unwind → `rollback_spec.rb`;
    - StepWorker hooks → `observability_spec.rb`.
  - Delete the file.
- [X] T059 [US7] Fold `spec/ruby_reactor/step_coordination/review_fixes_round3_spec.rb` the
  same way, then delete it:
  - inline declaration on a class step, and the guard-suppressed async_step →
    `single_site_spec.rb`;
  - the ceiling escalation → `park_spec.rb`;
  - async_step in a composed child → `park_spec.rb`;
  - the nested direct call → `attribution_spec.rb`.
- [X] T060 [US7] Fold `spec/ruby_reactor/step_coordination/review_fixes_round4_spec.rb` the
  same way, then delete it:
  - the deadlock guard with a key proc that raises → `rollback_spec.rb`;
  - the once-per-window step whose output contract rejects → `primitives_spec.rb`;
  - the redelivery of a finished async_step → `park_spec.rb`.
- [X] T061 [US7] Verify the layout.
  - `ls spec/ruby_reactor/step_coordination | grep review_fixes` prints nothing.
  - `bundle exec rspec spec/ruby_reactor/step_coordination --dry-run` equals the
    `baseline.md` total plus the examples added in T006, T021, T028, T045 and T053.
  - Add a "Finding → spec" table (F1–F10 → file and example description) to
    `specs/005-step-coordination-remediation/baseline.md`.

**Checkpoint**: all user stories are complete.

---

## Phase 10: Polish & Cross-Cutting Concerns

- [X] T062 [P] Add entries to `CHANGELOG.md`.
  - **Bug Fixes**, one line each for F1–F10, in user terms.
  - **Features**: `rollback_wait:` on `with_lock` and `with_semaphore`,
    `Failure#rollback_failures`, the `:snooze_step` middleware event, and the
    `have_rollback_failure` matcher.
- [X] T063 Consistency pass over `README.md` and `./documentation` (**REQUIRED**, Constitution
  Development Workflow).
  - `grep -rn "current_step" documentation README.md` has no attribution advice left.
  - `grep -rn "configured \`wait:\`" documentation` finds no rollback text.
  - Every behavior in `contracts/public-api.md` §1–§5 is documented.
- [X] T064 `bundle exec rubocop` reports 0 offenses beyond the baseline one in `baseline.md`.
- [X] T065 The full `bundle exec rspec` is green. Rerun known load flakes alone before
  debugging (see the memory note on flaky specs).
- [X] T066 Docker acceptance (Constitution VI.4), from an **isolated compose project**, because
  the container names in `docker-compose.yml` are fixed and another worktree may own them.
  - Run
    `docker compose -p rr_step_locks -f docker-compose.yml -f <override with unique container_name and ports: !reset []> up -d --build demo-redis demo-sidekiq`.
  - Then
    `docker compose -p rr_step_locks run --rm --no-deps demo-app bash -c "bin/rails db:prepare && bin/rails demo:step_lock"`.
    Every section, 1–5, prints ✅.
  - Then
    `docker compose -p rr_step_locks run --rm -e RAILS_ENV=test demo-app bundle exec rspec spec/reactors/step_lock_demo_reactor_spec.rb`.
  - Ask before stopping another worktree's containers.
- [X] T067 Validate [quickstart.md](./quickstart.md). Every scenario R1–R6 and P1–P5 maps to a
  passing, behavior-named example (cross-check against the T061 table).

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (T001)** has no dependencies.
- **Foundational (T002–T004)** depends on T001. It blocks every story: T004's error classes
  are used by US2 and US3, and FR-025 requires T002 before any code.
- **US1 (Phase 3)**, **US3 (Phase 4)**, **US5 (Phase 7)** and **US6 (Phase 8)** each depend
  only on Foundational.
- **US2 (Phase 5)** depends on Foundational. It edits `step_coordination.rb`, like US1, US3 and
  US5 (different methods), so run it after US3 to avoid merge churn in that file.
- **US4 (Phase 6)** depends on US2's T028, because it shares `park_spec.rb`. Its library work
  is independent.
- **US7 (Phase 9)** depends on the behavior files existing: T006, T021, T028, T045 and T053.
- **Polish** depends on every story.

### User Story Dependencies

| Story | Depends on | Shares files with |
|---|---|---|
| US1 | Foundational | `step_coordination.rb` (rollback methods), `compose_step.rb#compensate` (US2 edits `#execute_child_reactor`) |
| US3 | Foundational | `step_coordination.rb` (the gate and lifecycle), `ordered_lock_support.rb` (US2 edits `fresh_ordered_lock_start?`) |
| US2 | Foundational (after US3, by recommendation) | `step_coordination.rb#around_run`, `ordered_lock_support.rb`, `compose_step.rb` |
| US4 | US2 T028 (the spec file) | `park_spec.rb` |
| US5 | Foundational | `step_coordination.rb#step_name` |
| US6 | none | `documentation/locks_and_semaphores.md` |
| US7 | the spec files of US1, US2, US3, US4 and US5 | all the step_coordination spec files |

### Within Each User Story

- Fixtures, then a failing spec (confirm the failure on `ca963444`), then the implementation,
  then docs, then a green run.
- Within US2, follow the rescue-site order T029→T038. T034 (admission) must land before T036
  (the compose resume choice).

### Parallel Opportunities

- **Foundational**: T003 runs in parallel with T002 (a different file).
- **Across stories, after Foundational**: the fixture tasks T005, T020, T027, T044 and T052 are
  all [P] (separate files).
- **Docs-only, which can ship at once**: T055 (F4) and T057 (F6) are independent of any code.
- **US1**: T007, T008 and T016 are [P] (`lockable.rb`, `ruby_reactor.rb`, `matchers.rb`).
- **US2**: T039 (OpenTelemetry) is [P] with T029–T038.
- **Polish**: T062 is [P].

---

## Parallel Example: after Foundational

```bash
# Fixtures for four stories at once (separate files under spec/support/reactors/):
Task: "T005 [US1] rollback_contention_reactors.rb"
Task: "T020 [US3] ordering_parity_reactors.rb"
Task: "T027 [US2] park_reactors.rb"
Task: "T052 [US5] attribution_reactors.rb"

# Docs-only fixes that ship immediately:
Task: "T055 [US5] coordinating_step in middlewares.md and locks_and_semaphores.md:866"
Task: "T057 [US6] nesting-order rule in locks_and_semaphores.md"

# US1 library pieces in parallel:
Task: "T007 rollback_wait: in dsl/lockable.rb"
Task: "T008 Failure#rollback_failures in ruby_reactor.rb"
Task: "T016 have_rollback_failure matcher in rspec/matchers.rb"
```

---

## Implementation Strategy

### MVP first (US1)

1. Phases 1 and 2 (T001–T004).
2. Ship the docs-only fixes T055 and T057 now. They carry no risk.
3. Phase 3 (US1, T005–T019). This is the saga-integrity fix, with the new public API, docs and
   demo.
4. **Stop and validate**: R1 is green, the `demo:step_lock` sections 4 and 5 print ✅, and the
   full suite is green.

### Incremental delivery

1. US1 (rollback): the MVP.
2. US3 (ordering): self-contained, and covered by the ordered-lock specs at both levels.
3. US2 (parks): the riskiest. Run the full suite, then the T041 audit.
4. US4 (background step state) and US5 (attribution).
5. US6 (docs) and US7 (layout), then Polish.
6. After implementation, the mandatory `/speckit-review` hook (`after_implement`) runs. The
   review should now be able to group any finding by behavior file (US7).

---

## Notes

- [P] means a different file with no dependency on an incomplete task. Same-file edits are
  sequential even across stories.
- Every repro must be seen failing on `ca963444` before its fix (Constitution III, FR-027).
- FR-029: an existing spec may change its expectation only when it encodes a defect fixed here,
  or the removed D4 mechanism (T040).
- Commit after each task or checkpoint. End commit messages with the Co-Authored-By trailer.
