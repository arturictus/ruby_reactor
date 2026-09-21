---

description: "Task list for Step-Scoped Coordination"
---

# Tasks: Step-Scoped Coordination

**Input**: Design documents from `specs/003-step-lock-declarations/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/dsl-surface.md, quickstart.md

**Tests**: REQUIRED. Constitution III makes test-first mandatory: write each story's specs first,
watch them fail, then implement. Real Redis always (`docker compose up -d redis-test`). Any
worker/park claim uses the live-Sidekiq lane (`spec/support/real_async_backend.rb`,
`RealAsyncBackend.start_sidekiq!`). `Sidekiq::Testing.inline!` is never allowed in these specs:
it re-enters the worker inside the frame that holds the lock.

**Organization**: Grouped by user story. The plan's Phase 2 outline maps as: plan 1 → Phase 2,
plan 2 → US1/US2, plan 3 → US4, plan 4 → US3, plan 6 → US5, plan 5 → US6, plan 7 → US7/US8,
plan 8 → US5 (cont.), plan 9 → Polish.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: User story the task belongs to (US1–US8)

## Findings from the code that the tasks below encode

Read these before starting. Each was found in the current code and is not in plan.md.

1. **Registry pop is wrong for nesting.** `Executor#release_locks` (`lib/ruby_reactor/executor.rb:612,621`)
   calls `held_lock_keys.delete(key)`, which removes *every* occurrence. With a reactor and a
   step both holding K, the step's release would erase the reactor's entry, and the async
   deadlock guard would stop seeing K. Pop one occurrence instead (T031).
2. **Retry attempts would be charged for contention.** `RetryManager#prepare_retry_attempt`
   increments `retry_context.step_attempts` before every attempt. A contention park must give
   that increment back, or a busy key eats the retry budget meant for real failures (T024).
3. **`InterruptBuilder < StepBuilder`.** Once `StepBuilder` gets the five macros, interrupt
   steps inherit them. They have to be overridden to raise (D6) (T008).
4. **`Context#with_step` restores `current_step` in `ensure`.** When a contention error unwinds
   out of the step, `current_step` goes back to its old value, which is `nil` for a first step.
   The park path must set `@context.current_step` *after* unwinding (the rescue in
   `safe_execute_step_sync`). Otherwise the redelivery looks like a first run
   (`Executor#first_execution?`) and consumes the reactor-level rate limit and period gate a
   second time (T025).
5. **`async_step` defers argument resolution** (`step_executor.rb:81`). The dispatcher never
   resolves the step's args, so it cannot compute the step's key without extra work. The
   dispatch-time guard resolves args only when that cannot block (T034).
6. **The async_step worker has no delayed re-enqueue.** Routers expose `perform_step_async`
   only. Parking an `async_step` body needs `perform_step_in` on both routers (T036).
7. **Contention ceiling and delay**: reuse the existing `lock_snooze_max_attempts`,
   `lock_snooze_base_delay`, `lock_snooze_jitter` config, and `Worker#compute_snooze_delay`'s
   hint logic. They mean the same thing and satisfy FR-017 with no new config. The contention
   counter lives on `RetryContext` (plan/research D4), not in `private_data`. data-model.md's
   ContentionState table is superseded on that one point.

## Shared names used across tasks

- `RubyReactor::Executor::StepCoordination`, in `lib/ruby_reactor/executor/step_coordination.rb`
  (Zeitwerk autoloads it).
- `StepCoordination::KeyError < RubyReactor::Error::Base`: key proc raised, or returned nil/empty.
- `StepCoordination::Contended < StandardError`: raised on contention. Carries `primitive`,
  `key`, `step_name`, `reactor_name`, `retry_after_seconds`, and `original` (the underlying
  `Lock::AcquisitionError` / `Semaphore::AcquisitionError` / `RateLimit::ExceededError` /
  `OrderedLock::WaitError`). Message: `"<Reactor> step :<step> could not acquire <primitive> '<key>': <original message>"`.
- Coordination source for a step: `step_config` for inline declarations, falling back to
  `step_config.impl` for class declarations. The fallback lives in `StepConfig`'s readers (T007),
  so callers only ever read `step_config.lock_config` and the other four.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Test harness shared by every concurrency spec in this feature

- [ ] T001 Bring up `redis-test` and run `bundle exec rspec` and `bundle exec rubocop` on the untouched branch. Save the pass/fail counts to `specs/003-step-lock-declarations/baseline.txt`; SC-012 is checked against it at the end
- [ ] T002 [P] Create `spec/support/step_coordination_helpers.rb` with an `OverlapRecorder`. `enter(tag)` and `leave(tag)` RPUSH `"#{tag}:#{Process.pid}:#{Thread.current.object_id}:#{Process.clock_gettime(Process::CLOCK_REALTIME)}"` to the Redis list `step_coord:trace:<run_id>`, so the recorder works across threads and the live Sidekiq process. Add `max_concurrency(tag)` and `overlapped?(tag_a, tag_b)`, both computed from the list. Include the helper in specs tagged `:step_coordination`
- [ ] T003 [P] Create `spec/support/reactors/step_coordination_reactors.rb` with the fixture step classes and reactors shared by the specs and the live worker. Examples: `LockedChargeStep` (`with_lock { |a| "acct:#{a[:account_id]}" }`), `SleepyStep`, `RecordingStep`. Every body calls `OverlapRecorder`. `spec/support/sidekiq_boot.rb` already requires `reactors/*.rb`, so the live worker loads them. Confirm the recorder is reachable there: require `step_coordination_helpers.rb` from the fixture file, not from `spec_helper`
- [ ] T004 Create the `spec/ruby_reactor/step_coordination/` directory. In `spec/support/step_coordination_helpers.rb`, tag every example group in it `:step_coordination` via `RSpec.configure { |c| c.define_derived_metadata(file_path: %r{/step_coordination/}) { |m| m[:step_coordination] = true } }`, so T002's helper is included automatically

---

## Phase 2: Foundational (Declaration surface, no enforcement)

**Purpose**: Steps can declare the five primitives, and the declarations can be inspected. Nothing is enforced yet. Every story depends on this phase.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [ ] T005 [P] Write `spec/ruby_reactor/step_coordination/declaration_spec.rb` and confirm it fails. Cover:
  - (a) A class including `RubyReactor::Step` can call all five macros; the per-macro readers (`lock_config`, etc.) return the same hashes the reactor form builds.
  - (b) `with_rate_limit(:name, limit: 1)` still raises `ArgumentError`, and `with_period(every: :bogus)` still raises at class load.
  - (c) A subclass inherits the parent's configs, and redeclaring a primitive replaces the parent's.
  - (d) `declares_coordination?` is false for a bare step and true once any macro is used.
  - (e) `coordination_declarations` returns `{ lock: {...}, semaphore: {...} }` with only the declared keys.
  - (f) An inline `step :x do with_lock { ... } end` exposes `lock_config` on its `StepConfig`.
  - (g) `StepConfig#lock_config` falls back to `impl.lock_config` when the block declares nothing, and the block wins when both declare.
  - (h) `with_lock` inside an `interrupt` block raises at class definition, and the message names reactor-level coordination as the alternative.
  - (i) Reactor-level `lock_config` is unchanged for an existing reactor.
- [ ] T006 Make steps host the macros in `lib/ruby_reactor/step.rb`: in `Step.included`, also `base.extend(RubyReactor::Dsl::Lockable::ClassMethods)`. `Lockable::ClassMethods#inherited` already propagates configs to subclasses. Leave the macro definitions untouched
- [ ] T007 Add introspection to `lib/ruby_reactor/dsl/lockable.rb`: `coordination_declarations` (hash of the five configs, nils compacted, keys `:lock, :semaphore, :rate_limit, :period, :ordered_lock`) and `declares_coordination?` (`!coordination_declarations.empty?`). Reactors get these too, which is additive. In `lib/ruby_reactor/dsl/step_builder.rb`:
  - `StepBuilder` does `include RubyReactor::Dsl::Lockable::ClassMethods`, so the macros become builder instance methods.
  - `build` passes `lock_config:`, `semaphore_config:`, `rate_limit_config:`, `period_config:`, `ordered_lock_config:` into `StepConfig`.
  - `StepConfig` stores them and defines each reader as `@lock_config || (impl.lock_config if impl.respond_to?(:lock_config))`, and likewise for the other four.
  - `StepConfig` also defines `coordination_declarations` and `declares_coordination?` over those readers.
- [ ] T008 In `lib/ruby_reactor/dsl/interrupt_builder.rb`, override `with_lock`, `with_semaphore`, `with_rate_limit`, `with_period`, `with_ordered_lock` so each raises `RubyReactor::Error::ValidationError` (research D6). Message: `"interrupt :#{@name} cannot declare step-level coordination: its body is split across a pause, so a hold would span the gap. Declare it on the reactor (with_lock etc.) instead."`
- [ ] T009 Create the `lib/ruby_reactor/executor/step_coordination.rb` skeleton with no enforcement yet.
  - Define `KeyError` and `Contended` per "Shared names".
  - `initialize(step_config:, arguments:, context:, reactor_class:, middlewares:, owner: nil, park: true)`.
  - `#key_for(config)`: call `config[:key_proc].call(arguments)`. Raise `KeyError` naming the step and the cause if the proc raises, or if the result is nil or `to_s.empty?`.
  - `#owner`: the explicit `owner:`, else `(context.root_context || context).context_id`, else `SecureRandom.uuid` when the context is nil.
  - `#wait_for(configured)`: return `0` when `park && context&.inline_async_execution`, else `configured`. This mirrors `Executor#contention_wait`.
  - `#push_key(key)` / `#pop_key(key)` on `root.private_data[:held_lock_keys] ||= []`. Pop removes ONE occurrence via `index` + `delete_at`.
  - `#around_run { }` and `#around_rollback { }` just `yield` for now.
  - Add `self.none?(step_config)`, returning `!step_config.respond_to?(:declares_coordination?) || !step_config.declares_coordination?`, so the executor can skip construction entirely (plan: one nil check per step)
- [ ] T010 Run `declaration_spec.rb` and get it green. Run the full `bundle exec rspec`: no existing spec may change result (FR-027)

**Checkpoint**: Declarations exist and are inspectable; runtime behavior is unchanged

---

## Phase 3: User Story 1 - A step class declares the lock it needs (Priority: P1) 🎯 MVP

**Goal**: `with_lock` on a step class is taken right before the step body and released right after, keyed on the step's resolved arguments.

**Independent Test**: Two concurrent executions with the same key never overlap inside the step body. With different keys, they do overlap.

### Tests for User Story 1 ⚠️ (write first, confirm failing)

- [ ] T011 [P] [US1] Write `spec/ruby_reactor/step_coordination/lock_spec.rb` against real Redis, using two `Thread`s running sync `Reactor.run`, each with `with_lock(wait: 5)` so the loser blocks instead of failing. Cover:
  - (1) Same key: `OverlapRecorder.max_concurrency(:charge) == 1` across 20 iterations (SC-001).
  - (2) Different keys: `overlapped?` is true.
  - (3) After a successful locked step, the next step observes `expect("acct:1").not_to be_locked` (SC-003).
  - (4) The step body returns `Failure` and the key is free afterwards.
  - (5) The step body raises and the key is free afterwards.
  - (6) Reactor input `account_id: 1` plus a step `argument :account_id, input(:account_id), transform: ->(v) { v + 100 }` locks `"acct:101"`, not `"acct:1"`.
  - (7) The key proc raises, or returns nil, or returns `""`: the reactor result is a Failure naming the step and the cause, and the body's recorder tag never appears (SC-011, FR-007).
  - (8) A step suppressed by `where { false }` leaves no lock and no `:lock_acquired` event (FR-012).
  - (9) `with_lock(ttl: 1, auto_extend: true)` with a 2.5s body: a second thread with `wait: 0` gets contention throughout (FR-013).
  - (10) `fork` a child that takes the step lock and sleeps, `Process.kill("KILL", pid)`, then after `ttl` seconds a new run succeeds (SC-008).
  - (11) With the coordination Redis unreachable (point the adapter at `redis://127.0.0.1:1` for this example only, and restore it in `after`), the step fails with the connection error as cause and the body never runs.

### Implementation for User Story 1

- [ ] T012 [US1] Implement exclusive-lock acquisition in `StepCoordination#around_run`. When `step_config.lock_config` is present:
  - Build `RubyReactor::Lock.new(key, owner:, ttl: config[:ttl], wait: wait_for(config[:wait]), auto_extend: config.fetch(:auto_extend, true))`.
  - `acquire`, then `push_key(key)`, then `middlewares.on(:lock_acquired, key, context)`.
  - On `Lock::AcquisitionError`: `middlewares.on(:lock_failed, key, e, context)`, then raise `Contended` with `primitive: :lock`.
  - Yield. In `ensure`: release, logging and never raising (copy `Executor#release_one`), then `pop_key(key)` and `middlewares.on(:lock_released, key, context)`.
- [ ] T013 [US1] Wire enforcement into `lib/ruby_reactor/executor/step_executor.rb`. In both `execute_step_sync` and `execute_step_sync_without_result_handling`, replace the bare `run_step_implementation(step_config, resolved_arguments)` call AFTER `validate_step_arguments` with a private `run_coordinated(step_config, resolved_arguments)`:
  - Call `run_step_implementation` directly when `StepCoordination.none?(step_config)`.
  - Otherwise build `StepCoordination.new(step_config:, arguments: resolved_arguments, context: @context, reactor_class: @reactor_class, middlewares: @middlewares)` and call `.around_run { run_step_implementation(...) }`.
  - The guard check and validation stay before this point, so nothing is taken for a step that will not run (FR-012, D3).
- [ ] T014 [US1] In `StepExecutor#safe_execute_step_sync`, add `rescue StepCoordination::KeyError => e` BEFORE the generic `StandardError` rescue. Return `RubyReactor::Failure(e, retryable: false, step_name: step_config.name, reactor_name: @reactor_class.name, step_arguments: resolved_arguments, inputs: @context.inputs)`. Also add a temporary `rescue StepCoordination::Contended => e` returning the same shape with `exception_class: e.original.class.name`. US3 replaces this with the park/fail split
- [ ] T015 [US1] Run `lock_spec.rb` until green. Fix `StepCoordination` or the wiring, not the spec

**Checkpoint**: MVP. A class step's `with_lock` serializes that step in-process

---

## Phase 4: User Story 2 - Only the step is locked, not the whole workflow (Priority: P1)

**Goal**: Steps around a locked step keep overlapping across concurrent executions.

**Independent Test**: In an eight-step reactor whose third step locks a shared key, steps 1–2 and 4–8 overlap across two runs, and only step 3 serializes.

### Tests for User Story 2 ⚠️

- [ ] T016 [P] [US2] Write `spec/ruby_reactor/step_coordination/scope_spec.rb`. Build an eight-step fixture reactor in `spec/support/reactors/step_coordination_reactors.rb`: each step is a `RecordingStep` subclass that sleeps 0.2s, and step 3 declares `with_lock(wait: 10) { "shared" }`. Run two sync executions on threads and assert:
  - `OverlapRecorder.overlapped?` is true for steps 1, 2, 4..8 across the runs.
  - `max_concurrency(:step3) == 1`.
  - Total wall time is under `8 * 0.2 * 2` (SC-002).
  - Second example: while run B waits on step 3, run A's step 4 starts before B's step 3 starts (US2-2).

### Implementation for User Story 2

- [ ] T017 [US2] Run `scope_spec.rb`. If it fails, the cause is a hold outliving its step. Check that `StepCoordination` is local to `run_coordinated` (no ivar on `StepExecutor`) and that no reactor-level lock is acquired for a reactor that declares none. Fix in `lib/ruby_reactor/executor/step_executor.rb` / `lib/ruby_reactor/executor/step_coordination.rb`

**Checkpoint**: US1 and US2 green. The feature delivers its core value synchronously

---

## Phase 5: User Story 3 - Contention parks the execution instead of failing it (Priority: P1)

**Goal**: In a worker, losing contention requeues the execution at that step (`RetryQueuedResult`), with no compensation and bounded attempts. Synchronously it waits, then fails, and rollback runs.

**Independent Test**: Two worker-backed executions on one key both complete. The same pair run synchronously gives the loser a contention Failure.

### Tests for User Story 3 ⚠️

- [ ] T018 [P] [US3] Write `spec/ruby_reactor/step_coordination/contention_spec.rb`, live-Sidekiq lane (`RealAsyncBackend.start_sidekiq!`, skip with reason if it cannot boot). Cover:
  - (1) Two `background`-dispatched runs of a reactor whose `:charge` step is locked on the same key, with a 1s body: both contexts reach `completed`, the second's `execution_trace` has a `type: :contention_park, step: :charge` entry, and neither trace has a `:compensate` or `:undo` entry (SC-004, US3-1, US3-2).
  - (2) The `:charge` body recorder tag appears exactly once per execution.
  - (3) `config.lock_snooze_max_attempts = 2`, with the key held externally for the whole test (take a `RubyReactor::Lock` with a foreign owner in the spec process, since this is a lib spec, not demo): the context ends `failed`, and the failure message contains `"contention"`, the key, and `2` (FR-017, US3-5).
  - (4) A step with `retries max_attempts: 2` that is contended 3 times and then fails for real still gets 2 failure attempts: `retry_context.attempts_for_step(:charge) == 2` (Finding 2).
  - (5) Sync path: the key is held externally and `with_lock(wait: 1)`. `Reactor.run` returns a Failure after about 1s. Its message names the reactor class, `:charge`, and the key, and `exception_class == "RubyReactor::Lock::AcquisitionError"`. A prior step with `compensate` has run its compensation (US3-4, FR-016).
  - (6) A reactor with reactor-level `with_lock` on K1 and step `:charge` locked on K2, contended in a worker: across the park gap K1 stays held by the root context id (`expect("K1").to be_locked.by(ctx_id)`), and the `:lock_acquired` count for K1 is exactly 1, recorded through a fixture middleware that RPUSHes events to Redis (US3-3, FR-018).
  - (7) The contended step is the reactor's FIRST step, and the reactor has `with_rate_limit(limit: 1, period: :minute)`: the parked-then-resumed run still succeeds, meaning the rate limit was not charged twice (Finding 4).
  - (8) A `map` whose iteration step is locked on one key: every element completes (map elements park through `perform_map_element_in`).

### Implementation for User Story 3

- [ ] T019 [P] [US3] Add a contention counter to `lib/ruby_reactor/retry_context.rb`:
  - `attr_accessor :contention_attempts` (Hash, string step keys), initialized `{}`.
  - Methods `increment_contention_for_step(name)`, `contention_attempts_for_step(name)`, `clear_contention_for_step(name)`.
  - Include it in `reset`, `serialize_for_retry` (`contention_attempts:`), and `deserialize_from_retry` (`data["contention_attempts"] || {}`).
- [ ] T020 [P] [US3] Extract `Worker#compute_snooze_delay` and `#hinted_retry?` (`lib/ruby_reactor/worker.rb`) into public module functions `RubyReactor::Worker.snooze_delay(config, error)` / `.hinted_retry?(error)`. Keep the instance methods delegating so worker behavior is unchanged. `StepCoordination::Contended#retry_after_seconds` returns `original.retry_after_seconds` if it responds to it, so the hint logic works on the wrapper. Keep the `OrderedLock::WaitError` exclusion by checking `original`
- [ ] T021 [US3] In `lib/ruby_reactor/executor/retry_manager.rb`, split `requeue_job_for_step_retry` into:
  - `requeue_job(step_config, delay)`: everything after the `delay =` line, taking `delay` as a parameter. This keeps the map-element branch.
  - The existing method, which now computes the backoff and calls `requeue_job`.
- [ ] T022 [US3] Add public `RetryManager#park_for_contention(step_config, contended, reactor_class)`:
  - Increment `retry_context.contention_attempts` for the step.
  - If `config.lock_snooze_max_attempts != :infinity` and the count exceeds it, return `RubyReactor::Failure(<message "Step ':x' gave up on <primitive> '<key>' after N contention attempts">, retryable: false, step_name:, reactor_name:, exception_class: contended.original.class.name)`.
  - Otherwise set `delay = RubyReactor::Worker.snooze_delay(config, contended)` and `retry_context.next_retry_at = Time.now + delay`, call `requeue_job(step_config, delay)`, and return `RetryQueuedResult.new(step_config.name, retry_context.attempts_for_step(step_config.name), retry_context.next_retry_at)`.
  - Uncapped cases: `OrderedLock::WaitError` originals, the same exemption `Worker#handle_snooze` makes.
- [ ] T023 [US3] Make sure `RetryManager#handle_retry_result` passes a `RetryQueuedResult` returned from the block through unchanged. It already does; add a comment saying contention parks rely on this
- [ ] T024 [US3] Give back the failure-retry attempt on a contention park (Finding 2): add `RetryContext#decrement_attempt_for_step(name)` (floor 0) and call it at the start of `park_for_contention` before anything else, so `prepare_retry_attempt`'s increment for this round is undone
- [ ] T025 [US3] Replace T014's temporary `Contended` rescue in `StepExecutor#safe_execute_step_sync` with the park/fail split:
  - (a) Set `@context.current_step = step_config.name`. `with_step`'s ensure has already restored the old value (Finding 4).
  - (b) Append trace `{ type: :contention_park, step:, primitive: contended.primitive, key: contended.key, attempt: }`. Set `@context.private_data[:step_contention] = { step:, primitive:, key:, attempts:, next_attempt_at: }` for operators (US7).
  - (c) When `@context.inline_async_execution` is set, return `@retry_manager.park_for_contention(step_config, e, @reactor_class)`.
  - (d) Otherwise return the sync contention `Failure(e, retryable: false, exception_class: e.original.class.name, step_name:, reactor_name:, step_arguments:, inputs:)`.
  - On successful acquisition (in `around_run`, after all primitives are taken), clear `private_data[:step_contention]` and call `retry_context.clear_contention_for_step`.
- [ ] T026 [US3] Keep reactor-level holds across a contention park (FR-018, US3-3). In `Executor#resume_execution` (`lib/ruby_reactor/executor.rb`), after `@result` is computed: if `@result.is_a?(RetryQueuedResult) && @context.private_data[:step_contention]`, call `park_held_primitives!`, which sets `@parked` so the ensure skips `release_locks`. Then confirm that `consume_parked_primitives!` / reattach runs on the redelivery path that `requeue_job` → `Worker#perform` → `resume_execution` takes. If reattach is only wired for the `AsyncResultPending` redelivery, generalize the check to any resume that finds `private_data[:parked_primitives]`
- [ ] T027 [US3] Verify the map path in `lib/ruby_reactor/map/element_executor.rb`: a `RetryQueuedResult` from a contention park must take the existing "async retry requeued this element" branch. Adjust the condition only if it keys on something other than the result class
- [ ] T028 [US3] Run `contention_spec.rb` until green, then re-run `lock_spec.rb` and `scope_spec.rb`

**Checkpoint**: Contention parks in workers and fails synchronously, bounded, with no spurious compensation

---

## Phase 6: User Story 4 - Re-entrancy behaves exactly as nested workflows already do (Priority: P1)

**Goal**: Step holds follow the nested-reactor rules. They are owned by the root context, nesting is counted, they share one registry, and a hand-off that would deadlock is refused before dispatch. They are also honored on the `async_step` worker and on direct `Step.run`.

**Independent Test**: Reactor lock K, then step lock K, then compose child lock K: this completes. Handing K-declaring work to another process is refused, naming K.

**Depends on**: US3's `RubyReactor::Worker.snooze_delay` (T020), for T036.

### Tests for User Story 4 ⚠️

- [ ] T029 [P] [US4] Write `spec/ruby_reactor/step_coordination/reentrancy_spec.rb` and cover:
  - (1) Reactor `with_lock { "k:#{i[:id]}" }` plus a step locking the same key completes with no wait (`wait: 0`) (US4-1).
  - (2) A locked step whose body calls `ChildReactor.run` (sync compose-style) where the child has `with_lock` on K completes (US4-2, SC-006).
  - (3) Nested holds: inside the innermost body record `lock_info`. After the step releases but while the reactor still holds K, `expect("k:1").to be_locked` and `root.private_data[:held_lock_keys].count("k:1") == 1` (US4-3, FR-020, Finding 1).
  - (4) Two steps in one reactor locking the same key run in order and complete.
  - (5) A locked step's body dispatches `async_reactor` whose child `with_lock`s K: the result is a Failure whose message names K and the dispatching reactor, and no job is enqueued (US4-4, SC-007).
  - (6) The reactor holds K and a later `async_step` whose step class declares `with_lock` on K: refused at dispatch with the same message shape, and no StepWorker job (FR-022).
  - (7) Live-Sidekiq: an `async_step` with `with_lock` on K. While its body runs in the worker, `expect("K").to be_locked` and the owner is NOT the root context id (ownership never crosses the hand-off, US4-5). Two such dispatches on the same K never overlap (SC-005).
  - (8) `LockedChargeStep.run({ account_id: 1 }, nil)` called directly while K is held externally fails with the contention error after `wait`. When K is free it takes and releases K (FR-023).
  - (9) A step whose executor already took K does not double-take through the direct-invocation wrapper: exactly one `:lock_acquired` event.

### Implementation for User Story 4

- [ ] T030 [US4] Confirm the owner rule in `StepCoordination#owner` (T009): root context id for executor-driven runs, a per-call UUID when `context` is nil. No code change expected; add the `# re-entrancy: same owner as every reactor in this execution tree` comment
- [ ] T031 [US4] Fix `Executor#release_locks` in `lib/ruby_reactor/executor.rb` (Finding 1). Replace both `held_lock_keys.delete(key)` calls with a single-occurrence pop (`i = held_lock_keys.index(key); held_lock_keys.delete_at(i) if i`). Extract it as private `pop_held_lock_key(key)` so `StepCoordination#pop_key` has the same semantics
- [ ] T032 [US4] Also push the step's semaphore key to the registry when `limit == 1`, in `StepCoordination`, matching `Executor#acquire_semaphore`. The semaphore itself is implemented in US5 (T043); this task is the registry rule only, written so T043 calls it
- [ ] T033 [US4] Make the deadlock guard reusable from `lib/ruby_reactor/step/async_reactor_step.rb`:
  - Turn `held_lock_keys(context)` and `deadlock_message(key, child_class, context)` into public class methods.
  - Generalize the message's `"async_reactor dispatch of"` prefix to take a `kind:` (`"async_reactor"` / `"async_step"`) and name the dispatched step.
  - Add remedy text for async_step: "run the step inline (drop async_step) if it belongs inside the critical section".
- [ ] T034 [US4] Add a dispatch-time guard in `lib/ruby_reactor/executor/async_step_dispatch.rb#dispatch_async_step`, before `record_async_step_dispatch`:
  - Skip unless the root's held keys are non-empty and `step_config.lock_config` (or a `semaphore_config` with `limit == 1`) is declared.
  - Resolve the step's arguments non-blocking (Finding 5): if any argument source is a `RubyReactor::Template::Result` whose target has an `:async_step_ref`/`:async_reactor_ref` entry in `@context.composed_contexts` and no recorded intermediate result, skip the check and log `event="ruby_reactor.step_coordination.guard_skipped"` with reactor/step/execution_id.
  - Otherwise compute the keys (a `StepCoordination::KeyError` fails the dispatching step) and, on a collision, return `RubyReactor.Failure(Step::AsyncReactorStep.deadlock_message(...))` without enqueueing or writing the dispatch record.
- [ ] T035 [US4] Enforce coordination in the async_step worker, `lib/ruby_reactor/step_worker.rb`. In `run_step`, wrap each `execute_step_body` attempt in `StepCoordination.new(step_config:, arguments:, context:, reactor_class: context.reactor_class, middlewares: context.middlewares || RubyReactor::MiddlewareRunner.new([]), owner: @coordination_owner ||= SecureRandom.uuid, park: true).around_run { ... }`. The owner is per job and NEVER the root id (US4-5, D5 "ownership never crosses a hand-off"). The context is already marked `inline_async_execution`, so `wait_for` returns 0. Rescue `StepCoordination::KeyError` into a Failure record through `complete`
- [ ] T036 [US4] Park the async_step body on contention (Finding 6):
  - Add `perform_step_in(delay, root_context_id:, reactor_class_name:, step_context_id:, step_name:, contention_attempts: 0)` to `lib/ruby_reactor/adapters/sidekiq/router.rb` (`StepWorker.perform_in`) and `lib/ruby_reactor/adapters/active_job/router.rb` (`set(wait: delay).perform_later`), passing `"contention_attempts"` in the payload.
  - Make `StepWorker.slice_arguments` / `initialize` accept it.
  - In `StepWorker#run_step`, rescue `StepCoordination::Contended`. Over `lock_snooze_max_attempts` (unless `OrderedLock::WaitError`), `complete` a Failure naming the step, key, and attempts. Otherwise call `perform_step_in(RubyReactor::Worker.snooze_delay(config, e), ..., contention_attempts: n + 1)`, `log(:info, "parked", key:, attempt:)`, and return WITHOUT calling `complete`, so the Step Result Record stays `dispatched` and readers keep waiting.
- [ ] T037 [US4] Honor declarations on direct invocation (FR-023) in `lib/ruby_reactor/step.rb`:
  - Define `Step::DirectCoordination` with `def run(arguments, context = nil)`. It calls `super` when `!declares_coordination?` or when `Thread.current[:ruby_reactor_coordinated]&.include?(self)`.
  - Otherwise it does `StepCoordination.new(step_config: self, arguments:, context: (context if context.is_a?(RubyReactor::Context)), reactor_class: nil, middlewares: RubyReactor::MiddlewareRunner.new([]), park: false).around_run { super }`.
  - `Step.included` does `base.singleton_class.prepend(DirectCoordination)`. Because a subclass's own `def self.run` would sit ahead of the parent's prepend, also prepend in an `inherited` hook on `Step::ClassMethods` (call `super` first).
  - In `StepCoordination#around_run`, push `step_config.impl` (when present) onto `Thread.current[:ruby_reactor_coordinated] ||= []` for the duration of the yield and pop in `ensure`. That way an executor-driven run is never coordinated twice (test (9)).
  - Here `step_config:` is the step class itself. It already has the five readers (T006), but its `name` is the class name (a String), not a step symbol. In `StepCoordination`, derive attribution as `step_name = step_config.is_a?(RubyReactor::Dsl::StepConfig) ? step_config.name : step_config.name.to_s`, and use `step_name` everywhere a step name appears (events, errors, trace).
- [ ] T038 [US4] Run `reentrancy_spec.rb` until green. Re-run `spec/ruby_reactor/dsl/async_reactor_locks_spec.rb` and `spec/ruby_reactor/integration/locking_spec.rb` unchanged (SC-012)

**Checkpoint**: All P1 stories green. Reactor-level behavior is unchanged

---

## Phase 7: User Story 5 - The whole coordination family is available per step (Priority: P2)

**Goal**: Semaphore, rate limit, and period (dedup) work at step level, in the fixed order of contract §3. The ordered lock is Phase 11.

**Independent Test**: Each primitive declared on a step matches the reactor-level behavior narrowed to the step.

### Tests for User Story 5 ⚠️

- [ ] T039 [P] [US5] Write `spec/ruby_reactor/step_coordination/primitives_spec.rb` (semaphore, rate limit, period, ordering) and cover:
  - (1) `with_semaphore(limit: 2, wait: 10)`: 5 threads, `max_concurrency == 2`, all succeed (US5-1).
  - (2) `limit: 1` semaphore key appears in `held_lock_keys` during the body.
  - (3) `with_rate_limit(limit: 2, period: :minute)`: 3 sync runs give 2 successes and a 3rd Failure with `exception_class == "RubyReactor::RateLimit::ExceededError"`. In the live-Sidekiq lane the 3rd parks with `next_retry_at` about `retry_after_seconds` (US5-2).
  - (4) `with_rate_limit(:registered)` uses `config.rate_limits`. An unknown name gives a non-retryable Failure, not a park.
  - (5) `with_period(every: :hour)`: the second run in the bucket gives the step `be_skipped` (reason `:period`), later steps run, and the reactor result is Success, not Halt (FR-003, US5-3).
  - (6) The bucket is not marked when the step fails.
  - (7) Period plus lock: two threads racing the same bucket give exactly one body execution. The re-check under the lock closes the race (D3 step 6).
  - (8) A step declaring both lock and semaphore, and two different steps declaring the same pair, run concurrently without deadlock, and the release order is semaphore then lock, asserted through recorded `:semaphore_released` before `:lock_released` events (FR-008).

### Implementation for User Story 5

- [ ] T040 [US5] Restructure `StepCoordination#around_run` into the fixed order (contract §3, D3) so each primitive is a small private method:
  - ordered gate (stub until T060)
  - `period_seen?` fast check, which returns `RubyReactor.Skipped(nil, reason: :period, step_name:)` without yielding
  - rate limit
  - lock
  - semaphore
  - period re-check under the hold
  - yield
  - mark period on a plain Success (not `Skipped`, not `Halt`)
  - Release in reverse in nested `ensure`s. Add a `# order: see contracts/dsl-surface.md §3` comment
- [ ] T041 [US5] Implement the rate limit in `StepCoordination`, mirroring `Executor#check_rate_limit`:
  - Named config: `key_base = name.to_s` and `limits = RubyReactor.configuration.rate_limits.fetch(name)`. `UnknownLimitError` propagates as a normal non-retryable Failure, not `Contended`.
  - Inline config: `key_base = key_for(config)`.
  - `RubyReactor::RateLimit.new(key_base, limits:).check_and_increment!`. `ExceededError` becomes `Contended(primitive: :rate_limit)`.
- [ ] T042 [US5] Implement the period gate in `StepCoordination` using `RubyReactor::Period.key(key_for(config), config[:every])`, `storage_adapter.period_seen?`, and `period_mark(key, RubyReactor::Period.ttl_seconds(every))`, mirroring `Executor#check_period_gate` / `#mark_period_on_success`. The mark happens only after the body returns a plain Success
- [ ] T043 [US5] Implement the semaphore in `StepCoordination`:
  - `RubyReactor::Semaphore.new(key, limit:, wait: wait_for(config[:wait]))`, then `acquire` and `middlewares.on(:semaphore_acquired, key, limit, context)`, then the T032 registry push when `limit == 1`.
  - Failure: `:semaphore_failed` event, then raise `Contended(primitive: :semaphore)`.
  - Release: `:semaphore_released`, then pop.
- [ ] T044 [US5] Run `primitives_spec.rb` (non-ordered sections) until green

**Checkpoint**: Four of five primitives at parity

---

## Phase 8: User Story 6 - Coordination is re-taken to undo the work it protected (Priority: P2)

**Goal**: `compensate` and `undo` of a step run under that step's lock and semaphore, keyed from the same arguments. Rate limit, period, and ordered lock never gate them.

**Independent Test**: With a compensation that sleeps, a concurrent execution cannot enter the step's forward body until the compensation releases.

### Tests for User Story 6 ⚠️

- [ ] T045 [P] [US6] Write `spec/ruby_reactor/step_coordination/rollback_spec.rb` and cover:
  - (1) Step `:charge` has `with_lock`, succeeds, then a later step fails. During `:charge`'s `undo`, the recorder shows it holding `"acct:1"` (`lock_info` owner == root id) (US6-1).
  - (2) The undo sleeps 1s while a second thread runs the same reactor: `overlapped?(:charge_undo, :charge_run) == false` (SC-009, US6-2).
  - (3) The same for `compensate`, when `:charge` itself fails.
  - (4) `with_semaphore(limit: 1)` is re-taken for undo.
  - (5) A step with `with_rate_limit(limit: 1, period: :minute)` and `with_period` whose quota and bucket are already exhausted still runs its undo/compensate (US6-3, FR-025).
  - (6) The key is held externally during rollback with `wait: 0`: compensate yields `Error::CompensationError` whose message names the key, and undo leaves an `:undo_failure` trace entry naming the key. Neither is silently skipped (US6-4, FR-026).
  - (7) The live-Sidekiq lane: a compensation in a worker never parks. It waits the configured `wait` and then reports.

### Implementation for User Story 6

- [ ] T046 [US6] Implement `StepCoordination#around_rollback { }`:
  - Take only lock then semaphore (release in reverse), using the configured `wait` directly, NOT `wait_for`. Rollback never parks: the execution is already mid-failure.
  - Use the same `key_for(arguments)`, and the same owner, so it nests with any live reactor hold.
  - On `Lock::AcquisitionError` / `Semaphore::AcquisitionError`, return `RubyReactor::Failure("could not re-acquire <primitive> '<key>' for rollback of :<step>: <msg>", retryable: false, step_name:)` without yielding.
  - A `KeyError` returns the same shape.
- [ ] T047 [US6] Wrap both call sites in `lib/ruby_reactor/executor/compensation_manager.rb`, the `catch(StepSignals::TAG)` bodies inside `compensate_step` and `undo_step`, in `StepCoordination.new(step_config:, arguments:, context: @context, reactor_class: @context.reactor_class, middlewares:).around_rollback { ... }` unless `StepCoordination.none?(step_config)`. The existing `Failure` branches then report acquisition failure through `:failed_compensation` → `CompensationError`, and through `:failed_undo` → the trace, with no new reporting code
- [ ] T048 [US6] Run `rollback_spec.rb` until green

**Checkpoint**: Forward and rollback paths are both protected

---

## Phase 9: User Story 7 - Operators can see step coordination (Priority: P2)

**Goal**: Step holds and parks are visible in events, logs, the execution trace, and the dashboard, attributed to the step. A park is never shown as a failure.

**Independent Test**: While a step lock is held and another execution is parked on it, the dashboard payload and logs identify the step, key, and holder.

### Tests for User Story 7 ⚠️

- [ ] T049 [P] [US7] Write `spec/ruby_reactor/step_coordination/observability_spec.rb` and cover:
  - (1) A recording middleware receives `:lock_acquired`, `:lock_released`, and `:lock_failed` with the key, and `context.current_step == :charge` at each call (FR-028, US7-3). The same holds for semaphore events.
  - (2) A park emits one log line matching `event="ruby_reactor.step_coordination.parked" reactor=... step=:charge key="acct:1" primitive=:lock attempt=1 execution_id=...` (constitution IV: key=value).
  - (3) A parked context has `status` not `:failed`, has `private_data[:step_contention]` naming step/key/primitive, and emits no `:failed_step` for the park (US7-4).
  - (4) `RubyReactor::Web::CoordinationSerializer` output for a context whose `:charge` ran includes `steps: [{ step: "charge", primitive: "lock", key: "acct:1", state: ..., owner: ... }]`. For a parked context it includes `waiting: { step:, key:, primitive:, attempts:, next_attempt_at: }` (US7-1, US7-2, SC-010).
  - (5) The sync contention Failure's `step_name`, `reactor_name`, and message carry the reactor, step, and key (US7-2).

### Implementation for User Story 7

- [ ] T050 [US7] Emit `:failed_step` correctly around parks in `StepExecutor#execute_step` (`lib/ruby_reactor/executor/step_executor.rb`). A `RetryQueuedResult` from a contention park must go to `:complete_step`, as it does today for retry requeues; confirm this and add a comment. Add the structured `parked` log line in the T025 park branch, using the existing `log_async_event` formatting (extend it to accept extra key=value fields)
- [ ] T051 [US7] Attribute step events in `lib/ruby_reactor/open_telemetry.rb`: where lock/semaphore events are handled, add a `ruby_reactor.step` span attribute from `context.current_step` when present. If those events are not handled there, skip it and note that in the task
- [ ] T052 [US7] Extend `lib/ruby_reactor/web/coordination_serializer.rb` with `build_steps(reactor_class, context)`:
  - For each `reactor_class.steps` entry with `declares_coordination?`, find the latest `execution_trace` entry `type: :run, step: name` and compute the key from its `arguments` with the step's `key_proc`, rescuing to `key: nil, error:`.
  - Report lock state through the existing `build_lock` / `build_semaphore` helpers, and `state: "pending"` for steps not yet reached.
  - Add `waiting:` from `context.private_data[:step_contention]`.
  - Call it from the existing `build` call site in `lib/ruby_reactor/web/api.rb` and pass the context.
- [ ] T053 [US7] Render step-level entries in the dashboard coordination panel under `lib/ruby_reactor/web/public/`: one row per step with step/primitive/key/state/owner, plus a "waiting on" badge for `waiting`, visually distinct from failure
- [ ] T054 [US7] Add a matcher `have_contended_at(step_name)` to `lib/ruby_reactor/rspec/matchers.rb`. It matches a result/context whose `execution_trace` contains `type: :contention_park, step: step_name`, with an optional `.on(key)` chain. The demo spec needs it (Constitution VI), and it doubles as the shipped way to assert US7-4
- [ ] T055 [US7] Run `observability_spec.rb` until green

**Checkpoint**: Operators can see step, key, holder, and park status

---

## Phase 10: User Story 8 - Inline steps can declare coordination too (Priority: P3)

**Goal**: The inline `step :x do with_lock { } end` behaves exactly like the class form.

**Independent Test**: The US1 lock scenarios pass with an inline-declared step.

### Tests for User Story 8 ⚠️

- [ ] T056 [P] [US8] Write `spec/ruby_reactor/step_coordination/inline_spec.rb`:
  - Extract `lock_spec.rb` scenarios (1)–(5) into `shared_examples "step-scoped lock"`, parameterized by a `let(:reactor_class)`, and run them for a class-declared step and an inline-declared step with a `run` block.
  - Add: moving the inline declaration verbatim into a step class gives identical recorder output.
  - Add: an inline `compensate` block runs under the lock (US6 via `step_config`).

### Implementation for User Story 8

- [ ] T057 [US8] Run `inline_spec.rb`. The inline path is expected to work already via T007 + T013 (`run_block` goes through `run_step_implementation`). Fix only real gaps, such as `StepCoordination` reading `step_config.name` for attribution when there is no `impl`

**Checkpoint**: US1–US8 complete, apart from the step-level ordered lock

---

## Phase 11: User Story 5 (cont.) - Step-level ordered lock (Priority: P2, separable — cut first if schedule tightens)

**Goal**: `with_ordered_lock` on a step sequences executions at that step in arrival order. With `strict: true`, a failed earlier position short-circuits later positions at that step (`Skipped`), and the rest of the workflow continues.

**Independent Test**: Executions reaching the step out of order pass through it in arrival order. A failed position makes later positions skip the step.

### Tests for User Story 5 (cont.) ⚠️

- [ ] T058 [P] [US5] Add an ordered section to `spec/ruby_reactor/step_coordination/primitives_spec.rb`, live-Sidekiq lane. Cover:
  - (1) 5 background runs of a reactor whose FIRST step has `with_ordered_lock { "seq" }` and a random 0–0.3s body: the recorder shows step bodies in nonce order and never overlapping (US5-4).
  - (2) A later unordered step of run N may overlap run N+1's ordered step ("surrounding steps are unaffected").
  - (3) `strict: true` with position 2 failing: positions 3+ have the ordered step `be_skipped` with reason `:ordered_lock_chain_failed`, and their later steps still run (FR-004, US5-5).
  - (4) `strict: false`: every position runs.
  - (5) A contention redelivery reuses the same nonce: `private_data[:step_ordered_locks]["<step>"][:nonce]` is unchanged across parks.
  - (6) Poison-pill: a position that never arrives is advanced past after `poison_pill_timeout`.
  - (7) `have_ordered_lock_next` / `have_ordered_lock_last_completed` / `be_ordered_lock_drained` work on the step's key.
  - (8) The ordered lock is NOT re-taken for rollback (data-model rollback table).

### Implementation for User Story 5 (cont.)

- [ ] T059 [US5] Document the weaker guarantee on the macro itself in `lib/ruby_reactor/dsl/lockable.rb#with_ordered_lock`'s doc comment: "On a step, the position is assigned when the execution first REACHES the step (its key reads step arguments), so executions are ordered by arrival at that step, not by enqueue. Identical to the reactor form only when the step is first in its reactor." (research D8, contract §1)
- [ ] T060 [US5] Implement the ordered gate as the first stage of `StepCoordination#around_run`:
  - On first arrival, `RubyReactor::OrderedLock.assign(key, ttl:)`, stashing `{ key:, nonce:, epoch:, poison_pill_timeout:, ttl:, strict: }` in `context.private_data[:step_ordered_locks][step_name.to_s]`. Reuse it when present (redelivery).
  - Gate using the same `OrderedLock` API that `Executor::OrderedLockSupport#check_ordered_lock_gate` uses. Out of turn, raise `Contended(primitive: :ordered_lock, original: WaitError)`; it parks uncapped (T022). Synchronously the gate is not retried: it fails as contention.
  - With `strict` and a failed chain, return `RubyReactor.Skipped(nil, reason: :ordered_lock_chain_failed, step_name:)` without taking anything else.
  - Take nothing else while waiting for a turn (D3 step 1).
- [ ] T061 [US5] Add a per-step heartbeat and advance-on-terminal in `StepCoordination`:
  - Start a heartbeat thread for the duration of the step body, reusing the refresh call and interval from `OrderedLockSupport#start_ordered_lock_heartbeat` (extract a shared class method rather than copy if it is more than a few lines).
  - In `ensure`, when the step reached a terminal result (a Success, Skipped, or Failure value, and NOT a `Contended` raise), call `OrderedLockSupport.advance_with_retry(info, failed: result.is_a?(RubyReactor::Failure))` and delete the per-step stash.
- [ ] T062 [US5] Exclude the ordered lock from `around_rollback` (T046 already takes only lock/semaphore; add a spec-referenced comment), and exclude it from the async_step dispatch guard (T034 only considers lock and limit-1 semaphore)
- [ ] T063 [US5] Run the ordered section of `primitives_spec.rb` until green

**Checkpoint**: Five-primitive parity

---

## Phase 12: Polish & Cross-Cutting Concerns

**Purpose**: Docs, demo-app proof (Constitution VI), full-suite verification

- [ ] T064 [P] Update `documentation/locks_and_semaphores.md` with a new "Step-scoped coordination" section:
  - The five macros on a class step and an inline step.
  - The fixed acquisition order (contract §3).
  - The entry-point table (contract §3).
  - Contention on each path: parks in a worker, bounded by `lock_snooze_max_attempts`; waits then fails synchronously.
  - Re-entrancy rules and the dispatch refusal.
  - The rollback table.
  - `with_period` skipping the step, not halting.
  - The ordered-lock arrival caveat.
  - "Reactor level for 'this whole workflow is exclusive'; step level for 'this one operation is exclusive'" (FR-031).
- [ ] T065 [P] Update `README.md`: add a short step-level `with_lock` example to the locking section, linking to `documentation/locks_and_semaphores.md`
- [ ] T066 [P] Add a `CHANGELOG.md` entry under `Features`: "Steps can declare `with_lock`, `with_semaphore`, `with_rate_limit`, `with_period`, `with_ordered_lock`, keyed on their own arguments" (MINOR, additive)
- [ ] T067 [P] Create `demo_app/app/reactors/step_lock_demo_reactor.rb` (class `StepLockDemoReactor`) with class-based steps only:
  - `AuditStep` (unlocked, records), `ChargeStep` (`with_lock(wait: 2) { |a| "demo:acct:#{a[:account_id]}" }`, with `compensate` and `undo`), `NotifyStep` (unlocked), and a `fail_after_charge` input that makes a later step fail, to exercise compensation under the lock.
- [ ] T068 Register `demo:step_lock` in `demo_app/lib/tasks/demo_reactors.rake` with a `desc` and `[:environment, :flush_redis]`. It prints three sections:
  - (1) Serialized: two threads, same account. Print enter/leave times of `:charge` showing no overlap.
  - (2) Contended: two `background` runs on the same account. Wait for both to finish, then print both `completed` and the contention-park trace entry of the loser.
  - (3) Compensated: run with `fail_after_charge: true` and print the undo trace showing the lock held (`be_locked` equivalent printed via `RubyReactor::Lock` info, owner = context id).
- [ ] T069 Write `demo_app/spec/reactors/step_lock_demo_reactor_spec.rb` (`type: :reactor`) using ONLY `lib/ruby_reactor/rspec.rb` surface:
  - `test_reactor`, `be_success`, `have_run_step(:notify).after(:charge)`, `be_failure`, `be_locked`, `have_contended_at(:charge)` (T054), `drain_async_jobs`.
  - If holding a key from outside a reactor cannot be expressed with the shipped surface, add a helper `hold_lock(key, owner: "spec") { ... }` to `lib/ruby_reactor/rspec/helpers.rb` in this same change, with a spec in `spec/ruby_reactor/rspec/helpers_spec.rb`. Never hand-roll Redis calls in the demo spec.
- [ ] T070 Check `docker-compose.yml`: `demo-redis` and `sidekiq` must be present and wired so `docker compose run --rm demo-app bin/rails demo:step_lock` needs no manual setup (Constitution VI.4). Add a missing service or env var in the same change
- [ ] T071 Run `docker compose run --rm demo-app bundle exec rspec spec/reactors/step_lock_demo_reactor_spec.rb` and `docker compose run --rm demo-app bin/rails demo:step_lock`. Confirm the three printed sections match quickstart Scenario 6 (SC-013)
- [ ] T072 Run full `bundle exec rspec` and `bundle exec rubocop` (no `--disable-pending-cops`). Compare against `specs/003-step-lock-declarations/baseline.txt` (T001): no previously passing example may fail (SC-012). Then delete `baseline.txt`
- [ ] T073 Walk the quickstart.md acceptance checklist (SC-001…SC-013), map each row to the spec example that proves it, and fix any gap
- [ ] T074 Update the `Complexity Tracking` table in `specs/003-step-lock-declarations/plan.md` if the ordered-lock phase was cut or deferred. Mark data-model.md's `ContentionState` as superseded by `RetryContext#contention_attempts` + `lock_snooze_*` config (Finding 7)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: none
- **Foundational (Phase 2)**: depends on Setup. BLOCKS all stories
- **US1 (Phase 3)**: depends on Phase 2
- **US2 (Phase 4)**: depends on US1 (it verifies US1's scope)
- **US3 (Phase 5)**: depends on US1 (it replaces T014's temporary rescue)
- **US4 (Phase 6)**: depends on US1. T036 depends on US3's T020
- **US5 (Phase 7)**: depends on US1. T043 uses US4's T032 registry rule
- **US6 (Phase 8)**: depends on US1. The semaphore re-take in T046 needs US5's T043
- **US7 (Phase 9)**: depends on US3 (park trace/state) and US1
- **US8 (Phase 10)**: depends on US1. Its compensate example needs US6
- **US5 cont. (Phase 11)**: depends on US3 (the park path) and US5 (the fixed-order skeleton)
- **Polish (Phase 12)**: T067–T071 need US1, US3, US6, and T054. Docs can start after US4

### Story graph

```text
Setup → Foundational → US1 ─┬─> US2
                            ├─> US3 ─┬─> US4 (T036)
                            │        ├─> US7
                            │        └─> US5-ordered (Phase 11)
                            ├─> US4 ──> US5 (T032→T043) ──> US6 ──> US8 (compensate example)
                            └─> US8 (core)
                                                              └──> Polish
```

### Within each story

- The spec task comes first and must fail before implementation (Constitution III)
- `StepCoordination` changes come before call-site wiring
- The story's run-until-green task closes the phase

### Parallel opportunities

- T002, T003 (Setup): different files
- T005 alongside T006–T009 authoring (spec vs lib)
- Every story's spec-writing task ([P]) can be drafted as soon as Phase 2 lands. Write
  `lock_spec`, `scope_spec`, `contention_spec`, `reentrancy_spec`, `primitives_spec`,
  `rollback_spec`, `observability_spec`, and `inline_spec` in parallel
- T019 (retry_context.rb) and T020 (worker.rb) in parallel
- T064, T065, T066, T067 (docs and demo reactor) in parallel
- Note: most lib tasks touch `step_coordination.rb` or `step_executor.rb`, so lib work within and
  across stories is mostly sequential. Parallelism is in specs and docs, not lib

---

## Parallel Example: after Phase 2

```bash
# Draft all failing specs at once (different files):
Task: "T011 lock_spec.rb"
Task: "T016 scope_spec.rb"
Task: "T018 contention_spec.rb"
Task: "T029 reentrancy_spec.rb"
Task: "T039 primitives_spec.rb"
Task: "T045 rollback_spec.rb"

# Within US3:
Task: "T019 contention counter in lib/ruby_reactor/retry_context.rb"
Task: "T020 extract snooze_delay in lib/ruby_reactor/worker.rb"
```

---

## Implementation Strategy

### MVP (US1 only)

Phases 1 → 2 → 3. Stop and validate `lock_spec.rb`. A class step's `with_lock` then serializes
that step synchronously, which is the literal request.

### Incremental delivery

1. MVP (US1), then US2 (proves the value over reactor-level locks)
2. US3: worker parking. Required before anyone runs this in Sidekiq in production
3. US4: re-entrancy and hand-off refusal. With US1–US4 all P1 stories are done, and this is the
   release candidate for `with_lock`-only
4. US5 (semaphore/rate/period), US6 (rollback), US7 (observability), US8 (inline)
5. Phase 11 (ordered lock): separable, and the first to cut (plan Complexity Tracking)
6. Polish: the demo-app artifacts are required before merge (Constitution VI)

---

## Notes

- `[P]` = different files, no dependency on an incomplete task
- Commit after each phase checkpoint
- Never use `Sidekiq::Testing.inline!` in `spec/ruby_reactor/step_coordination/`
- The line numbers cited are from branch `step_validations` at commit `845b010`. Re-locate by
  method name if they have drifted
