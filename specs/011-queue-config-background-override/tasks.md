---

description: "Task list for 011 Per-Reactor/Step Queues"
---

# Tasks: Per-Reactor/Step Queues

**Input**: Design documents from `specs/011-queue-config-background-override/`

**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md),
[data-model.md](data-model.md), [contracts/](contracts/), [quickstart.md](quickstart.md)

**Tests**: REQUIRED by Constitution III (test-first, real Redis). In every phase, write the spec tasks
first and confirm they FAIL on the current code before implementing.

**Citations**:

- research findings and decisions: `F-n` / `R-nn`;
- data-model sections: `DM §n`;
- hop invariants and sequences: `H-n` / `P-n` (contracts/hop-protocol.md, crash windows in §3);
- public surface: `API §n` (contracts/api-surface.md).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: US1–US3 from spec.md

## Path Conventions

Single gem project: `lib/ruby_reactor/` (Zeitwerk-loaded, so new constants need no `require` when
the file name matches), `spec/`, `demo_app/`, `gui/`, `documentation/`.

**Test rules**:

- **Redis**: specs run against the test Redis at `redis://localhost:6780`. If another worktree's
  suite shares it, run on a separate DB with `RUBY_REACTOR_TEST_REDIS_URL=redis://localhost:6780/3`
  and rerun failures alone first.
- **Async paths**: use `for_each_async_backend` (`spec/support/async_backends.rb`) with
  `drain_async_jobs`. For single-job stepping use `QueueProbe.next_job` / `QueueProbe.pending`
  (`spec/support/queue_probe.rb`). For job placement use `PendingJob#queue` (T003).
- **No new `Sidekiq::Testing.inline!`.** Never stub executor, step-executor or compensation-manager
  internals. Crash windows are simulated at the router boundary, with a delegating double that
  raises once, or by replaying or deleting pending jobs.
- **Demo specs locally**: run `cd demo_app && REDIS_URL=redis://localhost:6780/5 RAILS_ENV=test
  bundle exec rspec …`. Don't run the gem suite and the demo suite at the same time.
- **Queue names**: stored and compared as Strings (`"stripe"`). Specs may declare them as Symbols.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: fixtures and job-placement helpers shared by every queue spec.

- [X] T001 Create `spec/support/queue_fixtures.rb`, module `QueueFixtures`. Its reactors build on
  `RollbackRecorder` (`spec/support/rollback_recorder.rb`, every recording step logs
  `run:` / `compensate:` / `undo:`). Its step classes are plain `RubyReactor::Step` subclasses that
  call `RollbackRecorder.record` in `run`/`undo`. Write the `queue` lines now. They will raise
  `NoMethodError` until T008, which is expected (the fixtures load lazily from the specs that use
  them; add the `require` there, not in `spec_helper`).

  Step classes:

  | Constant | Definition |
  | --- | --- |
  | `EmailStep` | `queue :emails`. `run` records `run:email`. No `undo` (it is used as an `async_step`) |
  | `AnotherStep` | `queue :another_one`. Records `run:another` and `undo:another`. Class attribute `fail_times` (default 0): fail the first N runs, then succeed |
  | `LedgerStep` | `queue :ledger`. Records `run:ledger` / `undo:ledger` |

  Reactors:

  | Constant | Definition |
  | --- | --- |
  | `Stripe` | `queue :stripe`. `recording_step :one`; `recording_step :two, after: :one` (tag `"s"`) |
  | `StripeWithLedger` | `queue :stripe`. `:one`; `step :two, LedgerStep` after `:one`; `:three` after `:two` |
  | `Undeclared` | No queue. `:u1`, `:u2` |
  | `Main` | `queue :main`; `background after: :first`. `recording_step :first`; `:second` after `:first`; `compose :bank_deposit, Stripe` waiting for `:second`; `:third` after `:bank_deposit` (tag `"m"`). The order is linear, so the hop count is deterministic |
  | `MainFailing` | `Main` with `:third` declared `fail: true` |
  | `MainNested` | As `Main`, composing `StripeWithLedger` (P-2) |
  | `MainUndeclaredChild` | As `Main`, composing `Undeclared` |
  | `MainLocked` | `Main` plus `with_lock { "qfx:lock" }` |
  | `MainSemaphore` | `Main` plus `with_semaphore(limit: 1) { "qfx:sem" }` |
  | `MainSteps` | `queue :main`; `background after: :first`; `:first`; `step :another, AnotherStep` after `:first`; `:after_another` after `:another`; `async_step :email, EmailStep` after `:first`. Also `async_step :priority_email, EmailStep do queue :priority_emails; wait_for :first end` and an undeclared inline `async_step :plain_async` |
  | `MainStepsFailing` | `MainSteps` with `:after_another` failing |
  | `StripeApproval` | `queue :stripe`. `:one`; `interrupt :approve, resume: :background` after `:one`; `:two` after `:approve` |
  | `MainApproval` | `queue :main`; `background after: :first`. `:first`; `compose :deposit, StripeApproval`; `:last` |
  | `RetryingStripe` | `queue :stripe`. A step that fails once with `retries max_attempts: 2, backoff: :fixed, base_delay: 0`. Check the keywords against `lib/ruby_reactor/dsl/retryable.rb:16` |
  | `MainRetry` | `queue :main`; `background after: :first`; composes `RetryingStripe` |
  | `Deposit` | `queue :deposits`; `input :i`; `recording_step :d, idx: true` |
  | `FanOutOwner` | `queue :main`; `background all: true`. `input :items`; `map :deposits, Deposit` with `fan_out batch_size: 2`, `source input(:items)`, `argument :i, element(:deposits)`. Then `recording_step :after_map` |
  | `InlineMapOwner` | As `FanOutOwner`, without `fan_out` |
  | `SoloMain` | `queue :my_specific_queue`; `background after: :first`. Linear `:first`, `:second`, `:third` |
  | `SoloAll` | `queue :my_specific_queue`; `background all: true`; `input :x, :integer` |
  | `SoloNoBackground` | `queue :my_specific_queue`; `:a`, `:b` |
  | `SoloUndeclared` | `SoloMain` without `queue` |
  | `SoloRetry` | `SoloMain` whose `:second` fails once with `retries max_attempts: 2, backoff: :fixed, base_delay: 0` |
  | `SoloApproval` | `queue :my_specific_queue`. `:first`; `interrupt :approve, resume: :background`; `:after` |

  Check the map DSL (`source`, `argument`, `element`) against `lib/ruby_reactor/dsl/map_builder.rb`
  and an existing map fixture (`spec/support/map_test_reactors.rb`).

  Helpers (module functions):

  - `QueueFixtures.queues_of_pending`: `RubyReactor::RSpec::AsyncTestHelpers.pending_async_jobs.map(&:queue)`.
  - `QueueFixtures.jobs_on(queue)`: the pending jobs whose `queue == queue.to_s`.
  - `QueueFixtures.run_log`: `RollbackRecorder.log`.
  - `QueueFixtures.count(event)`: occurrences of `event` in the log.

  Register `config.before(file_path: %r{spec/ruby_reactor/queues/}) { RollbackRecorder.reset! }`.
- [X] T002 [P] Write `spec/ruby_reactor/rspec/pending_job_queue_spec.rb`, `for_each_async_backend`.
  Enqueue one `Adapters::<backend>::Worker` job through the router and one with an explicit
  queue (Sidekiq `Worker.set(queue: "x").perform_async("id", "K")`; ActiveJob
  `Worker.set(queue: "x").perform_later("id", "K")`). `pending_async_jobs.map(&:queue)` returns
  the configured `queue_name` as a String (`"default"`) and `"x"`. It fails on current code
  (`NoMethodError queue`).
- [X] T003 Add `PendingJob#queue`:
  - in `lib/ruby_reactor/rspec/sidekiq_helpers.rb`: `raw["queue"]`;
  - in `lib/ruby_reactor/rspec/active_job_helpers.rb`: `raw[:queue].to_s`.

  T002 passes.
- [X] T004 [P] Baseline, with no file changes. Run `bundle exec rspec` (on its own Redis DB) and
  `bundle exec rubocop`. Record the example, failure and pending counts in a new
  `specs/011-queue-config-background-override/pr-description.md`. It is the regression bar for
  T074 (SC-002).

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**:

- the declaration DSL and the freeze (R-01);
- the resolver (R-02);
- queue-aware routers and jobs (R-03);
- the dispatch record (R-04);
- trace stamping (R-11).

**⚠️ CRITICAL**: no story work begins until this phase is complete.

### Part A: declarations and the freeze (R-01, API §1, DM §1)

- [X] T005 [P] Write `spec/ruby_reactor/queues/declaration_spec.rb`. Use `Class.new` fixtures so
  each example gets a fresh class. Cases:

  Declaring and reading:

  - (a) `queue :x` in a reactor body. `declared_queue == "x"`. The same for a step class.
  - (b) `queue :x` twice: no error. `queue :y` after it: `ValidationError` whose message names
    the class and both values. `queue nil`, `queue ""` and `queue 1`: `ValidationError` naming the
    class.
  - (c) A subclass with no declaration inherits `"x"`. A subclass declaring `:z` reports `"z"`,
    and the parent still reports `"x"`.

  The freeze:

  - (d) `MyReactor.queue(:z)`, `MyReactor.queue`, `StepClass.queue(:z)`, and an anonymous class's
    `queue(:z)` after its `Class.new` block each raise `RubyReactor::Error::StaticConfigurationError`
    with message exactly `"Can not modify static configurations in the runtime"`.
    `declared_queue` is unchanged afterwards.
  - (e) `self.queue :x` inside a class body works. `respond_to?(:queue)` is false (it is
    private).

  Step blocks:

  - (f) `step :a, StepClass do queue :block end` → `steps[:a].queue == "block"`, the block winning
    over the class's `"x"`. With no block declaration, `steps[:a].queue == "x"`. An inline step
    with neither: nil. The same three for `async_step`.

  Stubs:

  - (g) `queue :q` inside a `compose`, `map` or `async_reactor` block raises `ValidationError`
    whose message names the child reactor class and says to declare `queue` there.

  It must FAIL on current code.
- [X] T006 [P] Create `lib/ruby_reactor/error/static_configuration_error.rb`:
  `class StaticConfigurationError < ValidationError`, with default message
  `"Can not modify static configurations in the runtime"`, the same shape as
  `lib/ruby_reactor/error/deprecated_dsl_error.rb`.
- [X] T007 Create `lib/ruby_reactor/dsl/static_queue.rb`, module `RubyReactor::Dsl::StaticQueue`
  (R-01):
  - `self.normalize!(name, owner_label)`: returns `name.to_s`, or raises `ValidationError` unless
    `name` is a non-empty Symbol or String. Shared with `StepBuilder`.
  - **private** `queue(name)`:
    1. normalize;
    2. return if `@queue == value`;
    3. raise `ValidationError` ("#{label} already declares `queue :#{@queue}` and cannot also
       declare `queue :#{value}`") if `@queue` is already set;
    4. set `@queue`.
  - Public `declared_queue`: `@queue || (superclass.declared_queue if superclass.respond_to?(:declared_queue))`.
  - `method_missing(name, *args)`: raises `Error::StaticConfigurationError` when
    `name == :queue`, else `super`. `respond_to_missing?` stays `super` (so `respond_to?(:queue)`
    is false).
  - A `# ponytail:` comment: `send`/`class_eval` bypass the freeze; add a first-run seal if needed.
- [X] T008 Wire `StaticQueue`:
  - `include RubyReactor::Dsl::StaticQueue` inside `Dsl::Reactor::ClassMethods`
    (`lib/ruby_reactor/dsl/reactor.rb`). `ClassMethods` is extended onto the class, so the
    private `queue` becomes a private singleton method;
  - `extend RubyReactor::Dsl::StaticQueue` in `lib/ruby_reactor/step.rb`, next to the `Lockable` /
    `Retryable` extends.

  If Zeitwerk load order bites (`step.rb` loads early), `require_relative` it as
  `lib/ruby_reactor.rb:9-10` does for `lockable` / `retryable`.
- [X] T009 Step-block and builder declarations (R-01):
  - `lib/ruby_reactor/dsl/step_builder.rb`:
    - public `StepBuilder#queue(name)`: `@queue = Dsl::StaticQueue.normalize!(name, "step :#{@name}")`.
      A different second value raises, as R-01 does;
    - pass `queue: @queue` in `build`;
    - `StepConfig` stores it, with reader `StepConfig#queue`:
      `@queue || (impl.declared_queue if impl.respond_to?(:declared_queue))`. Compose and map
      configs have `ComposeStep`/`MapStep` as `impl`, which are `Step` subclasses with no
      declaration, so they return nil.
  - `lib/ruby_reactor/dsl/compose_builder.rb`, `map_builder.rb` and `async_reactor_builder.rb`:
    `def queue(*)` raises `Error::ValidationError`: "`queue` on `compose :#{@name}` is not
    supported: declare `queue` on #{child class name} instead". Same idiom as `ComposeBuilder#async`.

  T005 passes.

### Part B: the resolver and trace stamping (R-02, R-11, DM §2)

- [X] T010 [P] Write `spec/ruby_reactor/queues/resolution_spec.rb`, unit-level, building contexts
  by hand (`Context.new` with `parent_context` / `root_context` links, as `ComposeStep#link_contexts`
  does).

  `Queues.of_context`:

  - (a) a root with a declaration → it; without one → `configuration.queue_name.to_s`, read at
    call time (change `queue_name` mid-example, and the answer changes);
  - (b) a linked composed child with no declaration → the parent's; with one → its own;
  - (c) a root with `private_data["inherited_queue"] = "q"` and no declaration → `"q"`.

  `Queues.node_queue`:

  - (d) a plain step: block or class declaration, else `of_context`;
  - (e) a `compose` step: the child class's `declared_queue`, else `of_context`;
  - (f) an inline `map`: the element class's declaration, else `of_context`;
  - (g) a fan-out `map`, `async_step`, `async_reactor` and `interrupt`: always `of_context`.

  `Queues.dispatch_queue`:

  - (h) `async_step` → step queue, else `of_context`;
  - (i) `async_reactor` → child declaration, else `of_context`;
  - (j) a fan-out map → element declaration, else `of_context`.

  Other functions:

  - (k) `Queues.current(ctx)` reads `root.current_queue` for a nested context, and is nil when
    unset.
  - (l) `Queues.kwargs("default")` returns `{}` when `queue_name == :default`, and
    `Queues.kwargs("stripe")` returns `{ queue: "stripe" }`. `nil` returns `{}`.
  - (m) `Queues.declares_any?` is true for a reactor declaration, a plain step's class or block
    declaration, and (recursively) a compose or map child's declaration. It is false when only an
    `async_step` / `async_reactor` declares one, and false for an undeclared tree.

  Trace stamping:

  - (n) `ctx.append_execution_trace({type: :run, step: :a})` includes `queue: "stripe"` when
    `root.current_queue = "stripe"`, and no `queue` key when it is unset.
  - (o) `ContextSerializer.serialize` never writes `current_queue`. A round-trip leaves it nil.

  It must FAIL on current code.
- [X] T011 Create `lib/ruby_reactor/queues.rb`, `module RubyReactor::Queues` with `module_function`
  (R-02), implementing T010 (a)–(m):
  - **Node kind:**
    - `compose` is `impl == Step::ComposeStep`, with the child at
      `step_config.arguments[:composed_reactor_class][:source].value`;
    - `map` is `impl == Step::MapStep`, with the element at
      `arguments[:mapped_reactor_class][:source].value` and fan-out at
      `arguments[:fan_out][:source].value`. Confirm the keys in `dsl/compose_builder.rb#build`
      and `dsl/map_builder.rb#build_step_config`;
    - `async_dispatch` is `:step` or `:reactor`;
    - `interrupt?`.
  - **`declares_any?(reactor_class)`**: memoized on the class in `@__declares_any_queue`. It
    recurses through compose and map children, guarded against cycles with a visited set.
  - Every function returns a String or nil, never a Symbol.
- [X] T012 Context support in `lib/ruby_reactor/context.rb`:
  - `attr_accessor :current_queue` (transient). It is not added to `to_h` /
    `ContextSerializer`. Check `lib/ruby_reactor/context_serializer.rb` serializes an explicit
    field list, so nothing leaks.
  - `append_execution_trace`: merge `queue: q` when `(q = Queues.current(self))`. Keep the
    existing `background:` stamp.

  T010 passes.

### Part C: queue-aware routers, jobs and the dispatch record (R-03, R-04, API §4, DM §3.1, §4)

- [X] T013 [P] Write `spec/ruby_reactor/adapters/sidekiq/router_spec.rb` (new) and extend
  `spec/ruby_reactor/adapters/active_job/router_spec.rb`. For every router method (`perform_async`,
  `perform_in`, `perform_step_async`, `perform_step_in`, `perform_map_element_async`,
  `perform_map_element_in`, `perform_map_element_rollback_async`, `perform_map_element_rollback_in`,
  `perform_map_collection_async`), check three things.

  With `queue: "stripe"`:

  - (a) the job is on `stripe` (`PendingJob#queue`);
  - (b) the root `Worker` job's args are `[id, name, 0, "stripe"]` for `perform_async`, and
    `[id, name, snooze_count, "stripe"]` for `perform_in(..., snooze_count:)`. Hash payloads carry
    `"queue" => "stripe"`, and the map element methods carry `"owner_queue"` when given.

  Without `queue:`:

  - (c) args are byte-for-byte today's (`[id, name]`, hashes without `"queue"`). The job is on
    `configuration.queue_name` resolved **at enqueue time**: set `queue_name = :critical` after the
    adapters loaded, and every job class lands on `critical`. This is the F-1 fix, and on Sidekiq it
    covers `StepWorker` and the three map workers too.

  It must FAIL on current code.
- [X] T014 Routers (R-03, API §4):
  - **`lib/ruby_reactor/adapters/sidekiq/router.rb`**: every method takes `queue: nil`. The map
    element methods also take `owner_queue: nil`, and `perform_in` takes `snooze_count: 0`.
    Resolve `q = (queue || RubyReactor.configuration.queue_name).to_s` and enqueue with
    `Klass.set(queue: q).perform_async/perform_in(...)`. Append the job argument **only when
    `queue` was given**:
    - root Worker: `perform_async(id, name, 0, queue)` / `perform_in(delay, id, name, snooze_count, queue)`;
    - hash payloads: `merge("queue" => queue)` (and `"owner_queue"`).

    Return the same `DispatchResult`s.
  - **`lib/ruby_reactor/adapters/active_job/router.rb`**: the same, with
    `Klass.set(queue: q).perform_later(...)` and `set(queue: q, wait: delay)`, taking `.job_id`.
    `Adapters::ActiveJob::Compat` stays for the self-snooze paths.

  T013 passes.
- [X] T015 [P] Write `spec/ruby_reactor/storage/run_dispatch_record_spec.rb` (DM §3.1):
  - (a) `store_run_dispatch(id, "K", "stripe")` → `retrieve_run_dispatch(id, "K") == {"queue" => "stripe", "since" => <ISO8601 now>}`.
    The key is `reactor:K:context:<id>:dispatch`, with a TTL ≈ `context_ttl`.
  - (b) `clear_run_dispatch_wait(id, "K", "stripe")` empties `since` and keeps `queue`.
    `clear_run_dispatch_wait(id, "K", "other")` leaves it untouched.
  - (c) a missing record returns nil.
  - (d) with a record present, `scan_reactors` and `scan_reactors_page` return the reactor once
    and nothing for the record key (MGET returns nil for a hash), and the dashboard list is
    unaffected.

  It must FAIL on current code.
- [X] T016 Storage (R-04): in `lib/ruby_reactor/storage/redis_adapter.rb` (or a new mixin
  `storage/redis_run_dispatch.rb` included there, following `redis_locking.rb`), add:
  - `store_run_dispatch(context_id, reactor_class_name, queue)`: `HSET queue, since=Time.now.utc.iso8601`
    plus `EXPIRE context_ttl`;
  - `retrieve_run_dispatch`: `HGETALL`, nil when empty;
  - `clear_run_dispatch_wait(context_id, reactor_class_name, queue)`: `HSET since ""` only when the
    stored `queue == queue`. Plain HGET then HSET; mark it
    `# ponytail: non-atomic compare-and-clear; observability only, last writer wins`.

  Declare the three in `storage/adapter.rb` as `NotImplementedError` stubs. T015 passes.
- [X] T017 [P] Write `spec/ruby_reactor/queues/enqueue_run_spec.rb`:
  - (a) `Queues.enqueue_run(id, "K", queue: "stripe")` calls the router's
    `perform_async(id, "K", queue: "stripe")`. Use a delegating router double that asserts, at call
    time, that `retrieve_run_dispatch` already returns `queue: "stripe"`: the record is written
    before the enqueue (H-1).
  - (b) With no `queue:`, it uses the record's `queue`. With no record either, the root reactor's
    effective queue (resolve `"K"` with `Object.const_get`). With an undeclared reactor, the router
    gets **no** `queue:` keyword argument (`Queues.kwargs`).
  - (c) `delay: 5, snooze_count: 2` → `perform_in(5, id, "K", queue:, snooze_count: 2)`, with
    `snooze_count` passed only when a queue is passed.
  - (d) `router:` overrides `configuration.async_router` (the sweepers inject theirs).

  It must FAIL on current code.
- [X] T018 Implement `Queues.enqueue_run(context_id, reactor_class_name, queue: nil, delay: nil,
  snooze_count: nil, intermediate_results: {}, router: nil)` in `lib/ruby_reactor/queues.rb`
  (R-04):
  1. resolve the queue;
  2. `store_run_dispatch`;
  3. call `router.perform_async` or `router.perform_in` with `**kwargs(q)`, plus `snooze_count:`
     only when kwargs is non-empty;
  4. return the router's `DispatchResult`.

  T017 passes.
- [X] T019 [P] Write `spec/ruby_reactor/queues/worker_queue_spec.rb`, `for_each_async_backend`,
  with a stored `running` two-step context:
  - (a) `Worker.new.perform(id, name, 0, "stripe")` runs the steps, and each `:run` trace entry has
    `queue: "stripe"`. With no 4th argument, the entries have `queue: "default"`, because a job
    always knows its queue.
  - (b) With a record `{queue: "stripe", since: T}`, a job with `"stripe"` clears `since`, and a
    job with `"other"` leaves it.
  - (c) Make the reactor's `with_lock` key busy (`hold_lock`) for a job with `queue: "stripe"`.
    The snooze is enqueued on `stripe` with args `[id, name, 1, "stripe"]`, and the record's
    `since` is set.
  - (d) The same without a queue argument: the snooze uses `self.class.perform_in(delay, id, name, 1)`
    exactly as today (keep `spec/ruby_reactor/adapters/sidekiq/worker_spec.rb` green, unchanged).
  - (e) The pre-load lock-contention snooze (`lock_run`) also keeps the queue argument.

  It must FAIL on current code.
- [X] T020 Worker changes in `lib/ruby_reactor/worker.rb` (R-03, R-04):
  - `perform(context_id, reactor_class_name = nil, snooze_count = 0, queue = nil)`, threading
    `queue` through `lock_run` / `perform_locked` / `handle_snooze`.
  - In `perform_locked`, after `resolve_reactor_class!` and the paused check:
    `context.current_queue = (queue || configuration.queue_name).to_s`, then
    `storage.clear_run_dispatch_wait(context_id, reactor_class_name, context.current_queue)`.
  - In `handle_snooze`, before re-enqueueing, `storage.store_run_dispatch(context_id, name,
    queue || configuration.queue_name.to_s)`:
    - with a `queue` argument: `configuration.async_router.perform_in(delay, context_id, name,
      queue: queue, snooze_count: snooze_count + 1)`;
    - without one: the existing `self.class.perform_in(...)` line, unchanged.

  T019 passes. Then run `spec/ruby_reactor/adapters/{sidekiq,active_job}/worker_spec.rb`
  unchanged.

**Checkpoint**: declarations, resolution, placement and the record are ready. Every story can start.

---

## Phase 3: User Story 1 - Run a reactor's background work on its own queue (Priority: P1) 🎯 MVP

**Goal**: every job of a run, including the first hand-off, retries, parks, sweeper recovery and a
background interrupt resume, lands on the reactor's declared queue. Undeclared reactors are
unchanged.

**Independent Test**: `SoloMain` (`queue :my_specific_queue`, `background after: :first`) under
both backends. Every job the run produces is on `my_specific_queue`. `SoloUndeclared` produces
today's jobs on `default` (quickstart §2).

### Tests for User Story 1 ⚠️ (write first, confirm FAIL)

- [X] T021 [P] [US1] Write `spec/ruby_reactor/queues/reactor_queue_spec.rb`, `for_each_async_backend`,
  using `QueueFixtures`:
  - **AS1**: `SoloMain.run({})`. `run:first` is logged, and
    `queues_of_pending == ["my_specific_queue"]`. After `drain_async_jobs`, `be_success`, and each
    of `:second` / `:third` has `queue: "my_specific_queue"` on its `:run` trace entry (use
    `have_run_step(...).on_queue` once T028 lands; until then read the trace).
  - **AS2**: `SoloRetry`. After the hand-off, step job by job (`QueueProbe.next_job.perform!`): the
    retry requeue is on `my_specific_queue` (`QueueProbe.pending.map(&:queue)`), and the run ends
    `be_success`.
  - **AS3**: after the hand-off, delete the pending job (`AsyncTestHelpers.pending_async_jobs.first`,
    removed from the backend's store as `PendingJob#perform!` does) and run
    `RubyReactor::Sweeper.run_once`. The re-enqueued job is on `my_specific_queue`, and the run
    completes.
  - **AS4**: `SoloAll.run(x: 1)`. One job on `my_specific_queue`. `SoloAll.run(x: "bad")` enqueues
    one job on `my_specific_queue`, and the failure appears only after the drain (validation ran in
    the worker).
  - **AS5**: `SoloUndeclared`. Pending jobs are `["default"]`, and their args equal `[id, name]`
    exactly. The job count after the drain equals the count measured with the same reactor on
    current code (hard-code it, measured once while writing the spec).
  - **AS6**: `SoloNoBackground.run`. No pending jobs, `be_success`, and no trace entry has a
    `queue` key.
  - **Background interrupt resume** (US1 narrative): `SoloApproval` pauses in the caller, then
    `SoloApproval.continue(..., step_name: :approve)`. The resume job is on `my_specific_queue`,
    since there is no record and the reactor's effective queue applies (R-04 fallback).
- [X] T022 [P] [US1] Write `spec/ruby_reactor/queues/backend_placement_spec.rb` (F-1, FR-024):
  - (a) **Sidekiq only.** `RubyReactor.configure { |c| c.queue_name = :critical }` after load, then
    run a reactor that hands off (`SoloUndeclared`), dispatches an `async_step`, and fans out a map
    (`FanOutOwner` with `queue` removed via a `Class.new` copy). Every pending job, of every worker
    class, is on `critical`. Restore `queue_name` in `ensure`.
  - (b) **Both backends.** For `SoloUndeclared`, `MainSteps`-without-queues (a `Class.new` copy)
    and an undeclared fan-out map: no job carries a queue argument or a `"queue"` key.
- [X] T023 [P] [US1] Update `spec/ruby_reactor/sweeper_spec.rb` (R-10). With the injected `router`
  double:
  - (a) a running, unlocked run with record `{queue: "stripe"}` is re-enqueued with
    `perform_async(id, class, queue: "stripe")`;
  - (b) one with no record and an undeclared reactor still gets exactly
    `perform_async(id, class)` (existing expectations unchanged);
  - (c) when the record's `since` is set, one `event=ruby_reactor.queue.waiting` line with
    `queue="stripe"` and `source="sweeper"` is logged.
- [X] T024 [P] [US1] Write `spec/ruby_reactor/rspec/queue_matchers_spec.rb`, part 1 (R-12):
  - `have_run_step(:x).on_queue(:q)` passes when the `:run` entry's `queue == "q"`. It fails with
    the message "expected reactor to have run step :x on queue :q, but it ran on :other" (or "in
    the calling process" when there is no `queue` key).
  - It composes with `.after(:y)` and `.returning(v)`.
  - For an `async_step`, it reads the Step Result Record's `"queue"` (`subject.async_step(:x, :queue)`).
    Wire this assertion up in T054.

### Implementation for User Story 1

- [X] T025 [US1] `background all: true` placement in `lib/ruby_reactor/reactor.rb`. In `#run`'s
  async branch (line ~133) and in `perform_async_run` (line ~545), replace
  `configuration.async_router.perform_async(...)` with
  `Queues.enqueue_run(@context.context_id, RubyReactor.reactor_storage_name(self.class),
  queue: Queues.of_context(@context), intermediate_results: @context.intermediate_results)`.
  `save_context` stays before it.
- [X] T026 [US1] Hand-off target (R-06) in `lib/ruby_reactor/executor/step_executor.rb`
  `#handle_background_handoff`. Compute `q`:
  - `before:` → `Queues.node_queue(step_config, @context)`;
  - `after:` → `Queues.node_queue(@dependency_graph.ready_steps.first, @context)` (the result
    handler has already completed `step_config` in the graph, `result_handler.rb:174`), else
    `Queues.of_context(@context)` when nothing is ready.

  Pass it to `Queues.enqueue_run(root_id, reactor_class_name, queue: q, intermediate_results: ...)`
  in place of `configuration.async_router.perform_async`. Add `queue: q` to the
  `log_async_event("background.handoff", ...)` call. `checkpoint_root!` stays before it.
- [X] T027 [US1] Retry requeue in `lib/ruby_reactor/executor/retry_manager.rb#requeue_job`, root
  branch. Keep `store_context` first, then
  `Queues.enqueue_run(id, name, queue: Queues.current(@context), delay: delay)`. `current` is nil
  only in caller-process async reactors, where `enqueue_run` falls back to the record or the
  reactor queue. The map-element branch is T048.
- [X] T028 [US1] Matcher `on_queue` in `lib/ruby_reactor/rspec/matchers.rb` `have_run_step`:
  - `chain :on_queue { |q| @queue = q.to_s }`;
  - after `@entry` is found, compare `(@entry[:queue] || @entry["queue"])&.to_s`. When the entry
    is missing and the subject has an `async_step` reference for `step_name`, use
    `subject.async_step(step_name, :queue)`;
  - extend `failure_message` per T024.

  T024 passes, except the async_step example.
- [X] T029 [US1] Interrupt resume hand-offs in `lib/ruby_reactor/reactor.rb#hand_off_resume`:
  `Queues.enqueue_run(@context.context_id, name, intermediate_results: ...)`, with no explicit queue
  (the record, else the reactor's effective queue; US2-AS8 relies on the record).
- [X] T030 [US1] Sweeper in `lib/ruby_reactor/sweeper.rb`:
  `Queues.enqueue_run(reactor[:id], reactor[:class], router: @async_router)`. Before it, when
  `@storage.retrieve_run_dispatch(...)&.dig("since").to_s != ""`, log
  `event=ruby_reactor.queue.waiting reactor=… execution_id=… queue=… since=… source="sweeper"`.
  T021 AS3 and T023 pass.
- [X] T031 [US1] Run T021 and T022, and fix any gaps:
  - every remaining direct `async_router.perform_async(` call for a root Worker in
    `lib/ruby_reactor/reactor.rb` and `step_executor.rb`;
  - the ActiveJob `set(queue:)` path.

  Then run `bundle exec rspec spec/ruby_reactor/queues spec/ruby_reactor/sweeper_spec.rb
  spec/ruby_reactor/adapters`.
- [X] T032 [US1] Documentation (Constitution workflow; R-15):
  - **README.md**:
    - "Configuration": `queue_name` stays the global default, and units may declare `queue`;
    - "Background Execution": a `queue :my_specific_queue` example, where the hand-off and every
      retry, park, recovery and background resume use it;
    - a "Queues" Table of Contents entry.
  - **documentation/background_and_async.md**, a new "Queues" section:
    - declaring on reactors and step classes;
    - resolution order;
    - the static freeze (`StaticConfigurationError`, the exact message);
    - a queue never moves work out of the caller (FR-006);
    - placement of every job kind;
    - a note on `async_router` custom implementations (API §4).
  - **documentation/getting_started.md**: one line next to `config.queue_name`.
  - **documentation/testing.md**: `on_queue`, `PendingJob#queue`.
  - **CHANGELOG.md**:
    - Features: `queue` on reactors and step classes;
    - Bug Fixes: F-1;
    - migration notes: custom routers receive `queue:` once a queue is declared; Sidekiq step and
      map jobs move to a non-default `queue_name`.

**Checkpoint**: US1 is fully functional. A reactor can be moved to a dedicated queue with one line
(SC-005).

---

## Phase 4: User Story 2 - Composed children and maps run on their own queues (Priority: P2)

**Goal**: forward and rollback queue hops ("Option 1"), and the manual undo hand-off. Map element
jobs and the owner resume run on the right queues. Unsafe configurations are rejected. Every hop
keeps H-1–H-10.

**Independent Test**: `Main` + `Stripe`. Record the queue every step ran on. Inject a crash at
every window in hop-protocol §3, forward and rollback, and verify the run completes once or rolls
back fully (quickstart §3).

### Tests for User Story 2 ⚠️ (write first, confirm FAIL)

- [X] T033 [P] [US2] Write `spec/ruby_reactor/queues/compose_hop_spec.rb`, `for_each_async_backend`.

  Forward hops:

  - **AS1**: `Main.run({})`, drained job by job, counting jobs performed. The result is
    `be_success`, and:
    - `:second` and `:third` ran on `main`;
    - `subject.composed(:bank_deposit)` has `have_run_step(:one).on_queue(:stripe)` and `:two`
      on `stripe`;
    - `have_hopped_queues(:stripe, :main)`;
    - exactly 3 jobs were performed (SC-003);
    - each `run:` event appears once.
  - **AS2**: `MainUndeclaredChild`. The child steps run on `main`, there are no `:queue_hop`
    entries, and 1 job is performed.
  - **AS3**: in `Main`, `:first`'s successor `:second` shares the hand-off job with nothing in
    between (covered by the job count in AS1).
  - **P-2**: `MainNested` hops `stripe`, `ledger`, `stripe`, `main`. `run:ledger` happens once.
    There is no extra hop for the compose node while the child is in progress (H-9).
  - **Three-level compose** (edge case): root `main` → middle `:mid` → child `:leaf`. The hops are
    `mid`, `leaf`, `mid`, `main`, in that order. Build it with `Class.new` reactors.

  Holds and events:

  - **H-3 lease**: `MainLocked` with `context_lock_ttl = 2`. After the hop to `stripe`, sleep 3s
    without draining. `be_locked` on the lock key holds, by the run's root id. A second
    `MainLocked.run` handed off and drained once snoozes (still `running`). Draining everything
    completes both, the first before the second.
  - **H-3 semaphore**: with `MainSemaphore`, `have_held_tokens(1)` during the hop wait, and
    `have_available_tokens(1)` after completion.
  - **Events**: a middleware recording events shows no `:failed_step` / `:failed_reactor` for a hop,
    `:start_step` for `:bank_deposit` exactly once (in the `stripe` job), and
    `:before_async_enqueue` once per hop.
- [X] T034 [P] [US2] Write `spec/ruby_reactor/queues/hop_crash_windows_spec.rb`, `for_each_async_backend`.
  Use `Main` and the windows in hop-protocol §3. For each window, drive the run to the hop, then:

  - **W1, after the save, before the record**: perform the hop job, then delete both the new
    pending job and the run's dispatch record. Let the `async:` lock lapse: set `context_lock_ttl = 1` for the example and sleep 1.2s. Then
    `Sweeper.run_once` re-enqueues it to `main` (reactor fallback), and that job hops to `stripe`.
  - **W2, after the record, before the enqueue**: a delegating router double that raises
    `Redis::ConnectionError` once on the `stripe` enqueue. The job raises, and the record shows
    `stripe` since T. Then `Sweeper.run_once` re-enqueues it to `stripe`.
  - **W3, after the enqueue, before the old job releases**: duplicate the hop job's predecessor
    (re-push the same raw args before performing it, Sidekiq `Sidekiq::Client.push(raw)`, ActiveJob
    `enqueued_jobs << raw.dup`). Perform both. The second one dedupes: no new job, and no `run:`
    event.
  - **AS5, duplicate hop job**: re-push the `stripe` job's raw args and perform both copies.
    `run:s.one` happens once, and the second copy hops or exits without a `run:` event.

  Then drain. Every scenario ends `be_success`, with each `run:` event exactly once (SC-004).
  "No concurrent advance": every perform happens on one thread, and the lock is asserted held at
  each enqueue (spy on `Queues.enqueue_run` with `and_call_original`, asserting
  `storage.lock_held?("async:<id>")` inside it) (H-2).
- [X] T035 [P] [US2] Write `spec/ruby_reactor/queues/rollback_hop_spec.rb`, `for_each_async_backend`:
  - **AS6**: `MainFailing`, drained.
    - Expected events in order: `compensate:m.third`, `undo:s.two`, `undo:s.one`, `undo:m.second`,
      `undo:m.first`.
    - `compensate` ran on `main`.
    - `subject.composed(:bank_deposit)` has `have_undone_step(:two).on_queue(:stripe)`.
    - `have_undone_step(:second).on_queue(:main)` and `have_undone_step(:first).on_queue(:main)`.
      `:first` ran in the caller, and its undo runs on its effective queue.
    - `have_hopped_queues(:stripe, :main).during_rollback`, and `be_failure`.
    - Each undo happened once.
  - **AS10**: the W1, W2 and W3 analogues during rollback, at the hop into `stripe` and at the hop
    back. The sweeper re-enqueues the `rolling_back` run to the recorded queue. Each undo happens
    once, and the run ends `failed`.
  - **H-9**: with `MainNested` and `:third` failing, the child's `:two` (ledger) undo hops to
    `ledger` and back to `stripe`. The root never hops for the compose entry while the child's
    rollback is in progress. The hop sequence is exactly
    `stripe, ledger, stripe, main` (`.during_rollback`), so there is no loop.
  - **Caller rollback** (edge case): a `Main` copy whose `:first` fails (before the hand-off) rolls
    back in the caller, with no jobs and no `:queue_hop` entries.
- [X] T036 [P] [US2] Write `spec/ruby_reactor/queues/manual_undo_handoff_spec.rb`, `for_each_async_backend`:
  - **AS11**: `MainApproval` paused at `[:deposit, :approve]` after `:deposit`'s `:one` ran on
    `stripe` (drain to the pause).
    - `MainApproval.undo(id)` returns nil, and the reloaded run `be_rolling_back`.
    - One pending job is on the queue of `undo_stack.last`.
    - Meanwhile `MainApproval.undo(id)`, `MainApproval.cancel(id:, reason:)` and
      `MainApproval.continue(id:, payload: {}, step_name: [:deposit, :approve])` each raise
      `ValidationError`.
    - Drain. The run is `cancelled`, `undo:s.one` ran on `stripe` and `undo:m.first` on `main`.
  - **`undo(failure:)`**: an interrupt whose payload attempts run out triggers the same hand-off.
    After the drain the run is `failed`, with the failure reason.
  - **FR-018/FR-024**: an undeclared tree (a `Class.new` copy without queues) is undone in the
    caller: no jobs, and `cancelled` immediately.
- [X] T037 [P] [US2] Write `spec/ruby_reactor/queues/map_queue_spec.rb`, `for_each_async_backend`
  (AS7, FR-015):
  - (a) `FanOutOwner.run(items: [1, 2, 3])` hands off on `main`. After its job:
    - every `MapElementWorker` job is on `deposits`;
    - the `MapCollectorWorker` job is on `main`;
    - after the collector, the owner `Worker` job is on `main`.

    `be_success`.
  - (b) An element that fails once with `retries` (a `Deposit` copy with retries) requeues on
    `deposits`.
  - (c) A failure after the map (`after_map` failing) makes the element rollback jobs
    (`MapElementRollbackWorker`) run on `deposits`, and the owner resume on `main`.
  - (d) Map sweeper:
    - delete one element job, then `Map::Sweeper.run_once` re-dispatches on `deposits`;
    - delete the collector job after all elements settle, then the retrigger is on `main`;
    - delete one rollback job, then the re-dispatch is on `deposits`.
  - (e) `InlineMapOwner`: the map node hops into `deposits` and back
    (`have_hopped_queues(:deposits, :main)`), and the element steps ran on `deposits`.
  - (f) An undeclared element reactor: elements on `main` (the owner's), with no hops.
- [X] T038 [P] [US2] Write `spec/ruby_reactor/queues/child_redispatch_spec.rb`, `for_each_async_backend`:
  - **AS8**: `MainApproval`, drained to the pause, then `continue(..., step_name: [:deposit, :approve])`.
    The resume job is on `stripe` (the record), and it completes.
  - **AS9**: `MainRetry`. The child's retry requeue is on `stripe`.
  - **Contention snooze in the child**: hold the child reactor's `with_lock` key (a
    `RetryingStripe` copy with `with_lock`). The park snooze job is on `stripe`.
- [X] T039 [P] [US2] Write `spec/ruby_reactor/queues/definition_rejections_spec.rb` (R-09, API §2),
  using `Class.new` reactors and calling `validate_definition!`.

  Rejected:

  - (a) a fan-out map whose element has `step :x, LedgerStep` while the element declares
    `deposits`;
  - (b) the same, inline;
  - (c) an element with no declaration whose inner step declares one;
  - (d) a nested `compose` or `map` inside an element with a different queue;
  - (e) a `with_ordered_lock` reactor composing `Stripe`, or with a step class on `ledger`.

  Each raises `ValidationError` naming the reactor, the map or step, the unit and the reason
  (match the API §2 wording).

  Allowed (no raise):

  - (f) an element's inner `async_step` / `async_reactor` on another queue;
  - (g) an element inner step declaring the **same** queue as the element;
  - (h) `MainLocked`, `MainSemaphore`;
  - (i) a `with_ordered_lock` reactor whose units all resolve to its own queue.

  It must FAIL on current code.
- [X] T040 [P] [US2] Extend `spec/ruby_reactor/rspec/queue_matchers_spec.rb`, part 2 (R-12):
  - `have_hopped_queues(:a, :b)` matches the ordered `to` values of the root trace's forward
    `:queue_hop` entries. `.during_rollback` matches the rollback ones;
  - `have_undone_step(:x)`, and `.on_queue(:q)`, read `:undo` entries;
  - the failure messages list the actual sequence.
- [X] T041 [P] [US2] Extend `spec/ruby_reactor/lock_spec.rb` (create it if missing): `detach(lease: 30)`
  on a held lock sets its TTL to ≈30s and stops the extender, and `reattach` restores `ttl` and
  restarts it.

### Implementation for User Story 2

- [X] T042 [US2] Create `lib/ruby_reactor/error/queue_hop.rb`, `class QueueHop < ExecutionParked`
  with `attr_reader :queue, :step`, and message "queue hop to #{queue} at #{step}". In
  `lib/ruby_reactor/lock.rb`, add `def detach(lease: nil)`: `stop_extender`, then
  `adapter.lock_extend(@key, @owner, lease) if lease`. T041 passes.
- [X] T043 [US2] Forward hop check (R-05, P-1, H-5, H-8, H-9) in
  `lib/ruby_reactor/executor/step_executor.rb#execute_step`. Place it right after the
  "already completed" return and before `deferred_body`:

  ```ruby
  if (target = Queues.forward_hop_target(step_config, @context))
    raise_queue_hop!(step_config, target)
  end
  ```

  1. Add `Queues.forward_hop_target(step_config, ctx)` in `lib/ruby_reactor/queues.rb`. It returns
     the target, or nil when any of these holds:
     - `current(ctx)` is nil;
     - `node_queue == current`;
     - the node is a `compose` whose `ctx.composed_contexts[name]` already holds a `Context`
       (in progress, H-9).
  2. Add private `raise_queue_hop!(step_config, target)`:
     1. pin `@context.current_step = step_config.name`;
     2. append to the **root** context's trace
        `{type: :queue_hop, at: <path>, from: current, to: target, direction: :forward, timestamp: Time.now}`.
        `<path>` is the compose path joined with "." (walk `parent_context` collecting each
        parent's `current_step`);
     3. `@middlewares.on(:before_async_enqueue, root)`;
     4. `raise Error::QueueHop.new(queue: target, step: step_config.name)`.
- [X] T044 [US2] Holds across a hop (H-3) in `lib/ruby_reactor/executor.rb`:
  `park_held_primitives!(lease: nil)` calls `@acquired_lock.detach(lease: lease)`. In
  `execute`'s and `resume_execution`'s `rescue Error::ExecutionParked`, pass
  `lease: (e.is_a?(Error::QueueHop) ? RubyReactor.configuration.context_ttl : nil)`. `execute`
  currently rescues without binding `e`, so bind it.
- [X] T045 [US2] Worker hop in `lib/ruby_reactor/worker.rb#perform_locked`. Add
  `rescue Error::QueueHop => e` **before** the `ExecutionParked` clause, calling
  `hop!(context_id, reactor_class_name, context, e)`:
  - **dedupe**: when `(r = storage.retrieve_run_dispatch(...))` has `r["queue"] == e.queue` and a
    non-empty `since`, log `event=ruby_reactor.queue.hop … deduped=true` and return;
  - otherwise `Queues.enqueue_run(context_id, reactor_class_name, queue: e.queue)`;
  - log `event=ruby_reactor.queue.hop reactor= execution_id= step= from=<context.current_queue>
    to=<e.queue> direction="forward"`.

  It never calls `handle_snooze`. T033 (AS1–AS3, P-2, the three-level compose, H-3, the events)
  and T034 pass.
- [X] T046 [US2] Rollback hop (R-07, P-3, H-6, H-9):
  - `lib/ruby_reactor/error/rollback_handed_off.rb`: `initialize(map_id: nil, queue: nil,
    reactor_class_name: nil, message: nil)`, `attr_reader :queue`. The default message is
    "rollback handed off at map …" or "rollback hops to queue …".
  - `lib/ruby_reactor/queues.rb`: `rollback_hop_target(step_config, ctx)`. Nil when `current` is
    nil, when `node_queue == current`, or when the entry is a `compose` whose child context
    (`ctx.composed_contexts[name][:context]`) has a non-nil `rollback`.
  - `lib/ruby_reactor/executor/compensation_manager.rb#rollback_completed_steps`: before
    `undo_step`, `if (q = Queues.rollback_hop_target(step_info[:step], @context))`:
    1. append a root trace `:queue_hop` entry with `direction: :rollback`;
    2. `raise Error::RollbackHandedOff.new(queue: q)`, without popping.
- [X] T047 [US2] Rollback hand-off branch in `lib/ruby_reactor/executor.rb`:
  - `hand_off_rollback!(handed_off)`: when `handed_off.queue`, call
    `Queues.enqueue_run(@context.context_id, RubyReactor.reactor_storage_name(@reactor_class),
    queue: handed_off.queue)`, log `event=ruby_reactor.queue.hop … direction="rollback"`, and
    return. Otherwise the existing map handshake runs, its final `async_router.perform_async(...)`
    replaced by `Queues.enqueue_run(id, name)`.
  - `record_rollback_handoff`: the `DispatchResult` job_id becomes `"queue_hop:#{queue}"` for the
    queue variant.

  `Reactor#undo`'s existing `rescue Error::RollbackHandedOff` (`reactor.rb:231`) needs no change.
  T035 passes.
- [X] T048 [US2] Map forward plumbing (FR-015, AS7, DM §3.4):
  - **`lib/ruby_reactor/step/map_step.rb`**: compute `queue = Queues.dispatch_queue(config, context)`
    and `owner_queue = Queues.current(context) || Queues.of_context(owner_context)`.
    - `initialize_map_metadata`: pass `queue:` and `owner_queue:`. Extend
      `RedisAdapter#initialize_map_operation`'s keyword arguments to store them as `"queue"` and
      `"owner_queue"`, and update the stub in `storage/adapter.rb`.
    - `dispatch_async_map`: pass them in the `Dispatcher.perform` arguments.
    - `queue_collector`: `**Queues.kwargs(owner_queue)`.
  - **`lib/ruby_reactor/map/dispatcher.rb`**: `queue_element_job` and `requeue_index` pass
    `queue:` / `owner_queue:` (from the arguments, or `map_meta`). `settle_undispatched` passes
    the collector `queue: owner_queue`. All through `Queues.kwargs`.
  - **`lib/ruby_reactor/map/element_executor.rb`**:
    - `perform_element`: `context.current_queue = (arguments[:queue] ||
      configuration.queue_name).to_s`, and `context.private_data["inherited_queue"] ||= arguments[:queue]`;
    - `requeue_parked_element` and both `perform_map_collection_async` calls: pass `queue:`
      (element) or `owner_queue` (collector).
  - **`lib/ruby_reactor/executor/retry_manager.rb`**, map-element branch: pass
    `**Queues.kwargs(map_args[:queue])` and `owner_queue:`.
  - **`lib/ruby_reactor/map/collector.rb#signal_owner`**: `Queues.enqueue_run(owner_id, owner_class)`.
- [X] T049 [US2] Map rollback and sweeper plumbing:
  - `lib/ruby_reactor/map/step_rollback.rb#rollback_metadata`: add `queue: forward["queue"]`, and
    extend `start_map_rollback`'s stored fields (`storage/redis_map_rollback.rb`).
  - `map/dispatcher.rb#queue_rollback_job`: `**Queues.kwargs(meta["queue"])`.
  - `map/element_rollback.rb`: `requeue` passes the queue (from `args[:queue]`).
    `signal_owner_if_settled` calls `Queues.enqueue_run(args[:owner_context_id], args[:owner_reactor_class_name])`.
  - `map/sweeper.rb#retrigger_collector`: `**Queues.kwargs(meta["owner_queue"])`. Element
    re-dispatch goes through `Dispatcher.requeue_index`, already done in T048.

  T037 passes.
- [X] T050 [US2] Manual undo hand-off (R-08, P-4) in `lib/ruby_reactor/reactor.rb#undo`. After the
  reload and the second `rolling_back` guard, and after building `@context.rollback` as today, when
  `Queues.declares_any?(self.class)`:
  1. `@context.status = :rolling_back`;
  2. `executor.save_context`;
  3. `Queues.enqueue_run(@context.context_id, RubyReactor.reactor_storage_name(self.class),
     queue: top_queue)`, where `top_queue` is
     `@context.undo_stack.last ? Queues.node_queue(@context.undo_stack.last[:step], @context) :
     Queues.of_context(@context)`;
  4. `return :handed_off`. The lock is released by the `ensure`.

  Leave the undeclared path untouched. T036 passes. Check that `Executor#finish_undo` applies
  `failure_reason` (`executor.rb:1047`).
- [X] T051 [US2] Definition-time rejections (R-09):
  - `Queues.validate_definition!(reactor_class)` in `lib/ruby_reactor/queues.rb`, memoized per
    class (`@__queue_definition_checked`):
    - **map elements**: walk the element tree through `compose` and nested `map`, collecting
      hop-bearing units (plain steps, composes, nested maps) whose declared queue differs from the
      element reactor's own declaration (any declaration when it has none). Raise
      `Error::ValidationError` with the API §2 message;
    - **ordered lock**: when `reactor_class.ordered_lock_config`, walk the tree through `compose`
      for any hop-bearing unit whose declared queue differs from the reactor's.
  - Call it at the end of `Dsl::Reactor::ClassMethods#validate_definition!`
    (`lib/ruby_reactor/dsl/reactor.rb`).

  T039 passes.
- [X] T052 [US2] Matchers in `lib/ruby_reactor/rspec/matchers.rb` (R-12, API §8):
  - `have_hopped_queues(*queues)`, with `chain :during_rollback`. It reads the root
    `execution_trace` `:queue_hop` entries (symbol or string keys), filtered by `direction`;
  - `have_undone_step(name)`, with `chain :on_queue`.

  Both call `subject.ensure_executed!` first, like `have_run_step`. T040 passes.
- [X] T053 [US2] Documentation (R-15):
  - **documentation/background_and_async.md** "Queues":
    - hops (P-1 diagram, the job-count rule "one extra job per queue change");
    - rollback hops;
    - the manual undo hand-off;
    - waiting runs ("waits indefinitely, never failed for lag");
    - the rejected configurations;
    - a known limit: the sweeper re-enqueues waiting runs every sweep.
  - **documentation/composition.md**: a composed child's queue, hops in and out, an undeclared child
    inheriting.
  - **documentation/data_pipelines.md** (and `demo_app/documentation/data_pipelines.md` if it
    mirrors it): element queues, the collector and owner queues, and the no-hop-inside-elements
    rule.
  - **documentation/locks_and_semaphores.md**:
    - a lock lease across hops (`context_ttl`);
    - the ordered-lock rejection;
    - correct "Owner identity": the `background` hand-off releases and re-acquires the reactor
      lock (F-2), while hops keep it.
  - **documentation/testing.md**: `have_hopped_queues`, `have_undone_step`.
  - **README.md**: "Map & Parallel Execution", "Durability & Recovery" (recorded queue, waiting
    runs).
  - **CHANGELOG.md**:
    - Features: queue hops, rollback hops, the manual undo hand-off;
    - migration note: a reactor lock is held across a hop wait for up to `context_ttl`.

**Checkpoint**: US2 is fully functional and every crash window recovers (SC-003, SC-004, SC-006).

---

## Phase 5: User Story 3 - Steps declare their own queue (Priority: P3)

**Goal**: `async_step` / `async_reactor` jobs use the step's or child's queue, and a plain `step`
whose class declares a queue hops for that step, keeping its retries, compensation and undo on it.

**Independent Test**: `MainSteps`. The `async_step` job and its recovery are on `emails` while the
parent continues. `:another` runs on `another_one` between two hops, and its undo runs there when a
later step fails (quickstart §4).

**Dependencies**: T055–T058 (async dispatch) need only Phase 2 and can run in parallel with US2.
T059 (plain-step hops) needs T042–T047.

### Tests for User Story 3 ⚠️ (write first, confirm FAIL)

- [X] T054 [P] [US3] Write `spec/ruby_reactor/queues/step_queue_spec.rb`, `for_each_async_backend`.

  Async dispatch:

  - **AS1**: `MainSteps.run`, then perform the hand-off job. A `StepWorker` job is on `emails`, and
    the parent's next job is on `main`. After the drain, `have_run_step(:email).on_queue(:emails)`
    (record), and `subject.async_step(:email, :queue) == "emails"`.
  - **AS2**: the `:priority_email` job is on `priority_emails`.
  - **AS3**: the `:plain_async` job is on `main`.
  - **AS4**: delete the `emails` job, then `StepSweeper.run_once` re-dispatches on `emails`.
  - **AS5**: an `async_reactor :child, Stripe` in a `Class.new` copy dispatches the child `Worker`
    job on `stripe`, and the child's steps run there. An undeclared child (`Undeclared`) runs on
    `main`, through `inherited_queue`.

  Plain-step hops:

  - **AS6**: `have_hopped_queues(:another_one, :main)`; `:another` on `another_one`;
    `:after_another` on `main`.
  - **AS7**: a copy with `background after: :another` runs `:another` in the caller: no hop and no
    queue key on its trace entry.
  - **AS8**: `AnotherStep.fail_times = 1` with a retrying copy (`retries max_attempts: 2, backoff:
    :fixed, base_delay: 0` in the step block). The retry requeue job is on `another_one`.
  - **AS9**: `MainStepsFailing` gives `have_undone_step(:another).on_queue(:another_one)` and
    `be_failure`.
- [X] T055 [P] [US3] Update `spec/ruby_reactor/step_sweeper_spec.rb` (R-10). A record with
  `"queue" => "emails"` is re-dispatched with `perform_step_async(**args, queue: "emails")`, and
  `perform_step_in(0, ..., queue: "emails")` when it carries contention attempts. Records without
  `"queue"` keep today's exact calls.

### Implementation for User Story 3

- [X] T056 [US3] `async_step` dispatch in `lib/ruby_reactor/executor/async_step_dispatch.rb`:
  - `record_async_step_dispatch` stores `"queue" => Queues.dispatch_queue(step_config, @context)`;
  - `enqueue_async_step` calls `perform_step_async(..., **Queues.kwargs(q))`;
  - `log_async_event("async_step.dispatched", name, queue: q)`.
- [X] T057 [US3] `StepWorker` in `lib/ruby_reactor/step_worker.rb`:
  - read `@queue = arguments["queue"]` in `initialize`;
  - in `perform_unit`, after `load_step_context`, set
    `(context.root_context || context).current_queue = (@queue || configuration.queue_name).to_s`;
  - `handle_contention` passes `**Queues.kwargs(@queue)` to `perform_step_in`.

  In `lib/ruby_reactor/step_sweeper.rb#redispatch`, pass `**Queues.kwargs(record["queue"])` to both
  calls.
- [X] T058 [US3] `async_reactor` dispatch in `lib/ruby_reactor/step/async_reactor_step.rb#dispatch`:
  - set `child_context.private_data["inherited_queue"] = Queues.of_context(context)` before `save`;
  - replace the `perform_async` with `Queues.enqueue_run(child_context.context_id,
    RubyReactor.reactor_storage_name(child_class), queue: Queues.dispatch_queue(<this step's
    config>, context))`. The config is `context.reactor_class.steps[context.current_step]`, as in
    `run_inline?`;
  - add `queue=` to `log_dispatch`.

  T054 AS1–AS5 and T055 pass, as does T024's async example.
- [X] T059 [US3] Run T054 AS6–AS9. They exercise T043–T047 through `StepConfig#queue`. Fix any gap
  in `Queues.node_queue` for plain steps with a class or block declaration, or in
  `rollback_hop_target` (`lib/ruby_reactor/queues.rb`).
- [X] T060 [US3] Documentation:
  - **README.md** "Async Steps & Reactors": `queue` on a step class and in a step block (the block
    wins), `async_reactor` children, a plain step on its own queue hopping.
  - **documentation/background_and_async.md** "Queues": step-level queues and their recovery.
  - **CHANGELOG.md** Features: step-level `queue`.

**Checkpoint**: every user story works independently.

---

## Phase 6: Observability for waiting runs (FR-020, SC-007)

**Purpose**: the dashboard, API and logs show where a run waits and since when. Cross-cutting: it
needs Phase 2 and T045.

- [X] T061 [P] Write `spec/ruby_reactor/queues/waiting_on_spec.rb`, `for_each_async_backend`, with
  `Main` performed up to the hop to `stripe` and not drained:
  - (a) `retrieve_run_dispatch` is `{queue: "stripe", since: <set>}`, the status is `running`, and
    one `event=ruby_reactor.queue.hop` line has `from="main" to="stripe" direction="forward"`;
  - (b) `Sweeper.run_once` twice: still `running`, never `failed`, and `ruby_reactor.queue.waiting`
    is logged;
  - (c) after the `stripe` job is picked up, `since` is empty;
  - (d) a replayed predecessor job on `main` does not clear it (H-7);
  - (e) `MainFailing` mid-rollback shows `rolling_back` with the record set.
- [X] T062 [P] Write `spec/ruby_reactor/web/api_waiting_on_spec.rb`, following the existing web
  specs (`spec/ruby_reactor/web/`). The reactor detail JSON has:
  - `waiting_on: {"queue" => "stripe", "since" => …}` while waiting, and `null` after completion;
  - `execution_trace` entries with `queue`;
  - `queue_hop` entries with `from`, `to` and `direction`;
  - async-step references with `queue`.
- [X] T063 `lib/ruby_reactor/web/api.rb` reactor detail (the block around lines 37–80):
  - add `waiting_on`: from `storage.retrieve_run_dispatch(id, class_name)` when its `since` is
    non-empty and the status is in `%w[running rolling_back]`, else nil;
  - add `"queue"` to `async_step_record` / `hydrate_async_step_ref` output (from the record) and to
    `hydrate_async_reactor_ref`. The child's queue comes from the child's dispatch record.

  T061 and T062 pass.
- [X] T064 GUI:
  - `gui/src/lib/reactors.ts`: types for `waiting_on`, trace `queue`, the `queue_hop` entries and
    the reference `queue`;
  - `gui/src/components/ReactorDetail.tsx`: a "Waiting on `<queue>` since `<local time>`" line
    while `waiting_on` is set, and the hop entries rendered in the timeline;
  - `gui/src/components/StepInspector.tsx`: the step's queue, from its run entry or async record.

  Add or extend tests under `gui/src/components/__tests__/`. Run `cd gui && npm test` (or the
  existing test script) and `npm run build`, then copy the build into `lib/ruby_reactor/web/public`
  as the previous GUI changes did (check `git log -- lib/ruby_reactor/web/public` for the
  procedure).

---

## Phase 7: Demo-App Proof of Feature (Constitution VI, FR-023)

**Purpose**: a runnable demo, a rake task, a spec and a Docker acceptance run. It may be generated
with `/speckit-demo-tests` and then checked against these tasks.

- [X] T065 [P] Create `demo_app/app/reactors/stripe_deposit_reactor.rb`. Step classes
  `StripeChargeStep` and `StripeSettleStep` (`RubyReactor::Step`, each with `run` and `undo` that
  print and append to a `QueueDemoLog`, following `StepRetryDemoLog` in
  `demo_app/app/reactors/step_retry_demo_reactor.rb`). `class StripeDepositReactor <
  RubyReactor::Reactor`: `queue :demo_stripe`, `input :amount`, `step :charge`, `step :settle`
  after `:charge`.
- [X] T066 Create `demo_app/app/reactors/queue_demo_reactor.rb`. Class-based steps in the same file:
  `ReserveOrderStep`, `ConfirmOrderStep` (fails when the input `fail_at_confirm` is true; with
  `compensate` and `undo`), and `QueueEmailStep` (`queue :demo_emails`). Define `QueueDemoLog` here
  if T065 doesn't.

  `class QueueDemoReactor < RubyReactor::Reactor`:

  - `queue :demo_orders`, `background after: :reserve`;
  - `input :amount`, `input :fail_at_confirm, optional: true`;
  - `step :reserve`;
  - `compose :deposit, StripeDepositReactor` (argument `amount`);
  - `step :confirm` after `:deposit`;
  - `async_step :email, QueueEmailStep` after `:confirm`.
- [X] T067 Add `demo:queues` to `demo_app/lib/tasks/demo_reactors.rake`, with a `desc` line
  describing it, and `[:environment, :flush_redis]`. It runs three scenarios, printing each step's
  queue (from the reloaded trace), the hops and the final status:
  1. a success;
  2. `fail_at_confirm: true` (compensation on `demo_orders`, undos on `demo_stripe` and
     `demo_orders`, `failed`);
  3. a successful run followed by `QueueDemoReactor.undo(id)` printing the hand-off, then waiting
     for `cancelled`.

  It polls `QueueDemoReactor.find(id)` until terminal (bounded), as other async demo tasks do. Add
  `:queues` to the `demo:all` prerequisites (line ~242).
- [X] T068 Create `demo_app/spec/reactors/queue_demo_reactor_spec.rb`, `type: :reactor`, using
  **only** the built-in surface (`test_reactor`, `composed`, `async_step`, `be_success`,
  `be_failure`, `be_rolling_back`, `have_run_step(...).on_queue`, `have_undone_step(...).on_queue`,
  `have_hopped_queues`, `pending_async_jobs` / `PendingJob#queue`). Cover:
  - the success path, with steps on their queues and `have_hopped_queues(:demo_stripe,
    :demo_orders)`;
  - the email on `demo_emails`;
  - the failure path, with undos on their queues and `.during_rollback` hops;
  - a manual undo hand-off.

  Run it locally (Path Conventions).
- [X] T069 `docker-compose.yml`: set the `demo-sidekiq` service `command` to
  `bundle exec sidekiq -q default -q demo_orders -q demo_stripe -q demo_emails`. Leave every other
  service unchanged.

---

## Phase 8: Polish & Cross-Cutting Concerns

- [X] T070 [P] `specs/future_improvements.md`: add three entries:
  - hops inside map elements (R-09 alternative: a per-index resume record, a resuming
    `Map::Sweeper`, and an element rollback hop protocol);
  - a sweeper grace for pending dispatches (F-6, R-10);
  - keeping reactor holds across the initial `background` hand-off (F-2).
- [X] T071 [P] Final documentation pass:
  - **README.md**: "Features" bullet and Table of Contents entries for Queues.
  - **documentation/README.md**: the index, if it lists sections.
  - **Consistency**: check every doc against `contracts/api-surface.md` for the error message text,
    the matcher names and the log events.
  - **CHANGELOG.md**: entries under the unreleased heading, with the R-13 migration notes. Do not
    edit `lib/ruby_reactor/version.rb` (release-please).
- [X] T072 [P] Run `grep -rn "async_router.perform_async\|async_router.perform_in" lib/`. Every
  remaining root-`Worker` dispatch must go through `Queues.enqueue_run`. The sweepers inject
  `router:`. Fix stragglers.
- [X] T073 Run `bundle exec rubocop` and fix offenses. Add no `--disable-pending-cops`, and add
  `rubocop:disable` only where existing files already do it for the same cop.
- [X] T074 Full suite on its own Redis DB: `RUBY_REACTOR_TEST_REDIS_URL=redis://localhost:6780/3
  bundle exec rspec`. Compare with T004: no new failures, and the new example count is recorded
  (SC-002).
- [X] T075 Walk [quickstart.md](quickstart.md) §1–§6, run every listed command, and tick each table
  row in `pr-description.md`.
- [X] T076 Docker acceptance (Constitution VI.4), in an isolated project because the container
  names are fixed:
  1. `docker compose -p rr-queues up -d demo-redis demo-sidekiq`;
  2. `docker compose -p rr-queues run --rm demo-app bin/rails demo:queues`. Confirm the printed
     queues, hops, undos and statuses match quickstart §7;
  3. stop `demo-sidekiq`, start a run, and confirm the dashboard (`/ruby_reactor`) shows
     "Waiting on demo_orders since …";
  4. restart `demo-sidekiq`, and confirm the run completes;
  5. `docker compose -p rr-queues down`.

  Optionally drive it with the `demo-app-e2e-verify` skill.
- [X] T077 Finish `specs/011-queue-config-background-override/pr-description.md`:
  - a summary;
  - the spec revisions (R-17);
  - the migration notes (R-13);
  - the test counts before and after;
  - the Docker acceptance output.

---

## Implementation notes (deviations, recorded during /speckit-implement)

- **T013**: both routers are covered by one shared spec, `spec/ruby_reactor/adapters/router_queue_spec.rb`
  (`for_each_async_backend`), instead of a new Sidekiq file plus an edit to the ActiveJob one.
- **T019/T020, T048**: the existing mock-based `spec/ruby_reactor/adapters/{sidekiq,active_job}/worker_spec.rb`
  and `spec/ruby_reactor/step/map_step_spec.rb` gained `allow` stubs for the new collaborators (`current_queue=`, `clear_run_dispatch_wait`,
  `store_run_dispatch`). No expectation changed.
- **T035 AS10**: the rollback crash windows live in `hop_crash_windows_spec.rb` (its `rollback` group),
  next to the forward ones.
- **T043/T046**: a `queue_hop` trace entry names its node under `at`, not `step`, so step lookups
  (`have_run_step`, the dashboard) never match a hop. Rollback hops dedupe like forward ones.
- **T045**: the Worker's hop, pickup and queue-aware snooze live in `Queues` (`hop!`, `picked_up`,
  `snooze_run`); `Worker#handle_snooze` routes a `QueueHop` to `Queues.hop!` before any snooze logic.
- **T050**: a handed-off manual undo still runs an aborted run's cut-off `compensate` first
  (`Executor#finish_undo` calls `compensate_pending!`, a no-op otherwise).
- **T056/T057**: an `async_step`'s terminal record keeps the queue it ran on (`run_fields["queue"]`).
- **T064**: `gui/src/lib/reactors.ts` is unchanged — the detail response is untyped; `stepQueue` lives
  in `gui/src/lib/stepBackground.ts`.
- **T074–T076**: the quickstart run surfaced that the Sidekiq `Worker`/`SweeperWorker` still read
  `queue_name` at class load for their own snoozes (an order-dependent spec failure); both now
  override Sidekiq's `get_sidekiq_options`, with a regression example in `backend_placement_spec.rb`.
  The Docker run needs `bin/rails db:prepare` before `demo:queues` (quickstart §7 updated).
- **T068**: the demo's manual undo uses a new `TestSubject#undo(process_jobs:)` helper (FR-021), with a
  gem spec in `spec/ruby_reactor/rspec/test_subject_undo_spec.rb`.

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: none. T001, T002 and T004 are parallel. T003 comes after T002.
- **Foundational (Phase 2)**: needs T001 and T003. It blocks every story.
  - Part A: T005, then T006 → T007 → T008 → T009.
  - Part B: T010, then T011 → T012. Needs T009 for `StepConfig#queue`.
  - Part C:
    - the specs T013, T015, T017 and T019 are parallel with each other;
    - T014 needs T013;
    - T016 needs T015;
    - T018 needs T011, T014 and T016;
    - T020 needs T012 and T018.
- **US1 (Phase 3)**: needs Phase 2. This is the MVP.
- **US2 (Phase 4)**: needs Phase 2. It reuses US1's `on_queue` matcher (T028) in its specs. Write
  them first anyway; they fail on the missing chain until T028 lands.
- **US3 (Phase 5)**: T054 to T058 need only Phase 2 and can run in parallel with US2. T059 needs
  T042–T047.
- **Observability (Phase 6)**: needs Phase 2 and T045 (a hop to wait on). T064 needs T063.
- **Demo (Phase 7)**: needs US1–US3 and T052 (the matchers). T065, T066 and T069 are parallel.
  T067 and T068 come after T066.
- **Polish (Phase 8)**: needs everything. T076 needs T069.

### Within Each Story

1. Write the spec tasks first and confirm they FAIL.
2. Error classes and primitives (T042) come before the checks (T043, T046), which come before the
   Worker and hand-off wiring (T045, T047).
3. Plumbing (T048, T049) and the undo hand-off (T050) are independent of each other. Both need
   T047.
4. Documentation closes each story.

### Parallel Opportunities

- **Phase 1**: T001, T002 and T004.
- **Phase 2**: the specs T005, T010, T013, T015, T017 and T019 together. T006 alongside T007.
- **US1**: the specs T021–T024 together. T025, T027, T029 and T030 touch different files.
- **US2**: the specs T033–T041 together.
  - T042 then T043/T044, which run in parallel (different files);
  - T046 alongside T048 and T049 (different files), then T047, T050, T051 and T052, which run in
    parallel.
- **US3**: T054 and T055 together. T056, T057 and T058 run in parallel.
- **Phase 6**: T061 and T062 together.
- **Phase 7**: T065, T066 and T069.

---

## Parallel Example: User Story 2

```text
# All US2 specs at once (each fails until its implementation lands):
T033 spec/ruby_reactor/queues/compose_hop_spec.rb
T034 spec/ruby_reactor/queues/hop_crash_windows_spec.rb
T035 spec/ruby_reactor/queues/rollback_hop_spec.rb
T036 spec/ruby_reactor/queues/manual_undo_handoff_spec.rb
T037 spec/ruby_reactor/queues/map_queue_spec.rb
T038 spec/ruby_reactor/queues/child_redispatch_spec.rb
T039 spec/ruby_reactor/queues/definition_rejections_spec.rb
T040 spec/ruby_reactor/rspec/queue_matchers_spec.rb (part 2)
T041 spec/ruby_reactor/lock_spec.rb

# After T042, different files in parallel:
T043 lib/ruby_reactor/executor/step_executor.rb + queues.rb#forward_hop_target
T044 lib/ruby_reactor/executor.rb (lease)
T046 lib/ruby_reactor/executor/compensation_manager.rb + rollback_handed_off.rb
T048 lib/ruby_reactor/{step/map_step,map/dispatcher,map/element_executor,map/collector}.rb
```

## Parallel Example: User Story 3 (alongside US2)

```text
T054 spec/ruby_reactor/queues/step_queue_spec.rb
T055 spec/ruby_reactor/step_sweeper_spec.rb
T056 lib/ruby_reactor/executor/async_step_dispatch.rb
T057 lib/ruby_reactor/step_worker.rb + step_sweeper.rb
T058 lib/ruby_reactor/step/async_reactor_step.rb
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Phase 1 (Setup), then Phase 2 (Foundational).
2. Phase 3 (US1). Stop and validate quickstart §1–§2. A reactor can declare `queue` and every job
   of its run lands there, on both backends, with undeclared reactors unchanged.
3. It is shippable on its own: placement only, no hops. A composed child or a step class declaring
   a different queue is simply not hopped yet. Document that limitation if releasing at this point.

### Incremental Delivery

1. Setup + Foundational + US1 → MVP (SC-001 for single reactors, SC-002, SC-005, SC-008).
2. US3 part 1 (async dispatch, T054–T058) can ship next, independently of hops.
3. US2 → hops, rollback hops, manual undo, maps (SC-003, SC-004, SC-006). Then T059 completes US3.
4. Observability (SC-007) → Demo → Polish → Docker acceptance.

### Notes

- Never stub reactor internals. Crash windows go through the router boundary or job replay (T034).
- Every hop path must keep "persist, record, enqueue, release". Assert it with the T034 spy.
- Commit after each task or logical group. Stop at any checkpoint to validate a story
  independently.
