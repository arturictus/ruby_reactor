# Feature Specification: ActiveRecord Storage Adapter

**Feature Branch**: `active_record_adapter`

**Created**: 2026-10-10

**Status**: Draft

**Input**: User description: "Now that we have a solid data model to manage reactors with redis I want to add an adapter for ActiveRecord, that will mean that user can decide if using Redis as a context and state store or a more persistent way in a relational database using ActiveRecord."

**Clarified with the user (2026-10-10)**:

- **Scope**: full replacement. The relational adapter covers everything the storage adapter does today: execution state *and* coordination (locks, semaphores, rate limits, periods, ordered locks, completion signals). A per-feature mix of adapters is a later feature.
- **Priority**: reliability. The relational adapter must meet every behavioral claim made in `README.md` and `documentation/`, and everything the current test suite verifies, before any new capability counts.
- **Why relational**: to keep the full history of executions and to query it in depth. It is not chosen to reproduce Redis's TTL expiry.
- **Databases**: PostgreSQL, MySQL and SQLite, each tested in CI.
- **Packaging**: the gem MUST NOT declare ActiveRecord as a runtime dependency. ActiveRecord can appear only in a Gemfile or, if there is no other choice, as a development dependency.
- **Schema**: migrations are versioned and upgradeable across gem releases.
- **Testing**: both adapters can be tested independently in the gem suite and in `demo_app`, with the adapter selected by an environment variable in CI.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Run reactors on a relational database with full parity (Priority: P1)

An application developer whose app already uses ActiveRecord sets RubyReactor's storage to the relational adapter, installs the schema, and runs their existing reactors unchanged. That covers synchronous runs, async steps, retries, maps (inline, batched and fan-out), composition, compensation and undo, interrupts with pause and resume, locks, semaphores, rate limits, periods, ordered locks, and sweeper recovery after a crash. Everything behaves exactly as documented for Redis.

**Why this priority**: Parity is the user's stated top priority. With a relational adapter that is only partly correct, users would trade a working Redis setup for silent saga corruption. Every other story depends on this one.

**Independent Test**: Run the gem's adapter-agnostic test suite with the relational adapter selected, against each supported database. Run the `demo_app` reactor specs and `demo:` rake tasks the same way. All pass with no change to reactor code.

**Acceptance Scenarios**:

1. **Given** an app configured with the relational adapter and the schema installed, **When** a reactor runs to success, **Then** its result, step outputs and execution record are identical to a Redis-backed run of the same reactor and inputs.
2. **Given** a reactor whose third step fails, **When** it runs on the relational adapter, **Then** compensation runs in reverse dependency order for completed steps, and the stored execution shows the failure with reactor name, step name, redacted inputs and reason.
3. **Given** a reactor with an async step and a worker process killed mid-step, **When** the sweeper runs after the liveness lock lapses, **Then** the execution is recovered exactly as documented for Redis.
4. **Given** two worker processes contending for the same `with_lock` key, semaphore, rate-limit window or ordered-lock sequence, **When** both attempt to proceed, **Then** the same exclusivity, limit and ordering guarantees hold as with Redis: no double grant, no lost token, no out-of-order run.
5. **Given** a reactor paused at an interrupt, **When** it is resumed from a different process (including by correlation ID), **Then** it resumes once, and duplicate resume deliveries are rejected as documented.
6. **Given** an app using the relational adapter and the ActiveJob queue backend with no Redis server reachable, **When** every `demo:` reactor task runs, **Then** all complete as documented, which shows a Redis-free deployment is possible.
7. **Given** an existing app on the Redis adapter, **When** it upgrades to the gem version that ships this feature and changes no configuration, **Then** behavior is unchanged and no ActiveRecord library is loaded or required.

---

### User Story 2 - Install and upgrade the schema with versioned migrations (Priority: P1)

An application developer installs the relational adapter's schema through the gem's provided install path. When a later gem release changes the schema, they get new, versioned migrations to apply. Existing migrations are never rewritten, and history recorded under the old schema is kept.

**Why this priority**: Without an installable schema the adapter cannot run at all. Without versioned upgrades, every gem release risks breaking or wiping stored history, which is the main reason to choose this adapter.

**Independent Test**: In a fresh app, run the install path and confirm the schema is created. Simulate an upgrade from schema version N to N+1 on a database holding history, confirm the history is still there, and confirm that booting with a missing or outdated schema fails with a clear message.

**Acceptance Scenarios**:

1. **Given** a host app with no RubyReactor tables, **When** the developer runs the documented install command and their normal migration command, **Then** the schema exists and the adapter is usable.
2. **Given** a database at schema version N holding execution history, **When** the developer upgrades to a gem release requiring version N+1 and applies the shipped migrations, **Then** all prior history is still present and readable.
3. **Given** the relational adapter is configured but the schema is missing or behind the version the gem requires, **When** the app first uses reactor storage, **Then** it fails fast with an error naming the expected and actual schema versions and the step to fix it, and writes nothing.
4. **Given** an app that uses ActiveRecord without Rails, **When** the developer follows the documented non-Rails install path, **Then** they can create and upgrade the schema.

---

### User Story 3 - Test both adapters independently (Priority: P2)

A gem maintainer, or CI, chooses the storage adapter with an environment variable. The full gem suite and the full `demo_app` suite then run against that adapter, and against each supported database for the relational adapter. Tests tied to one adapter's mechanics run only under that adapter. Each such test has an equivalent for the other adapter wherever the behavior is shared.

**Why this priority**: The parity promise in Story 1 can only be checked if both adapters are exercised on every change. The constitution requires real infrastructure, not mocks.

**Independent Test**: Run the suites locally with the environment variable set to each adapter value, then confirm the CI configuration runs one job per adapter/database combination.

**Acceptance Scenarios**:

1. **Given** the adapter environment variable is unset, **When** the gem suite runs, **Then** it uses Redis exactly as today.
2. **Given** the variable selects the relational adapter and a database, **When** the gem suite runs, **Then** every adapter-agnostic spec runs against that real database, and Redis-only specs are skipped with a stated reason.
3. **Given** CI on a pull request, **When** the workflow runs, **Then** the gem suite and the `demo_app` suite each run once for Redis and once per supported database for the relational adapter, and a failure in any of them fails the build.
4. **Given** a `demo_app` spec written with the built-in RSpec helpers and matchers (`be_locked`, `have_available_tokens`, `be_period_marked`, `be_paused`, …), **When** it runs under either adapter, **Then** it passes without any adapter-specific code in the spec.

---

### User Story 4 - Keep and query the full execution history from the dashboard (Priority: P2)

An operator opens the RubyReactor dashboard in an app that uses the relational adapter. They can see every execution ever recorded, not only the last `context_ttl` window. They can filter by reactor class, status, time range, and the value of an input, for example "all executions where `user_id` is 100".

**Why this priority**: Durable, queryable history is the user's main reason for choosing the relational adapter. It depends on Story 1 storing the data correctly.

**Independent Test**: Seed executions of several reactor classes and statuses across a wide time range, including some older than `context_ttl`. Filter in the dashboard by class, status, date range and an input value, and confirm each filter returns exactly the matching executions with paging.

**Acceptance Scenarios**:

1. **Given** an execution that finished longer ago than `context_ttl`, **When** the operator opens the dashboard, **Then** the execution and its step details are still listed and viewable.
2. **Given** executions with different `user_id` inputs, **When** the operator filters by `user_id = 100`, **Then** only executions whose inputs have `user_id` equal to 100 are listed.
3. **Given** filters by reactor class, status and time range combined, **When** applied, **Then** only executions matching all of them are listed, in pages.
4. **Given** an input configured as redacted, **When** the operator views or filters executions, **Then** the redacted value is never shown in plain text and cannot be used as a filter.
5. **Given** an app on the Redis adapter, **When** the operator opens the dashboard, **Then** it works as today, and the filters only the relational adapter supports are hidden or marked unavailable rather than failing.

---

### User Story 5 - Period markers that never expire (Priority: P3)

A developer uses `with_period every: :year` (or `:month`, `:week`, etc.) for once-per-period work. With the relational adapter, each claimed period is recorded permanently, together with the execution that claimed it and the time. The dedup guarantee therefore never depends on a marker outliving its TTL, and operators can see when each period ran.

**Why this priority**: The user named this as a gain of keeping full history. It mostly follows from Story 1, plus making the marker history visible.

**Independent Test**: Claim a `:year` period, advance time past the marker's Redis-equivalent TTL but stay within the same year, and confirm a second run is still deduplicated. Then confirm the marker records which execution claimed it and when.

**Acceptance Scenarios**:

1. **Given** a period bucket already claimed, **When** another run for the same bucket starts at any later time inside that bucket, **Then** it is halted as a duplicate, whatever time has passed.
2. **Given** a claimed period marker, **When** the operator inspects it (the current bucket in the dashboard's coordination panel, any bucket through the adapter's marker lookup or the database), **Then** it shows the bucket, the claiming execution and the claim time.

---

### User Story 6 - Run-level idempotency keys (Priority: P3)

A developer starts a reactor with an idempotency key. If an execution of the same reactor with the same key already exists, the original outcome is returned: its result or failure if it finished, or its current status if it is still running. The work is not run again. With the relational adapter the key is honored permanently. With Redis it is honored within the retention window.

**Why this priority**: The user named this as a gain of keeping full history. It adds a new public API surface, so it comes after parity and history.

**Independent Test**: Run a reactor with key K, then run it again with key K and different inputs. Confirm the second call returns the first execution's outcome and no step runs again. Repeat after advancing time past `context_ttl` under the relational adapter.

**Acceptance Scenarios**:

1. **Given** a successful execution started with key K, **When** the same reactor is started again with key K, **Then** the original result is returned and no step executes.
2. **Given** two processes start the same reactor with key K at the same moment, **When** both calls finish, **Then** exactly one execution exists and both callers observe it.
3. **Given** key K was used by reactor class A, **When** reactor class B is started with key K, **Then** B runs normally, because keys are scoped per reactor class.
4. **Given** the Redis adapter and an execution with key K older than `context_ttl`, **When** the reactor is started with key K, **Then** it runs as new. This bound is documented.

---

### Edge Cases

- **Host transaction around a run**: A reactor is started inside an application database transaction that later rolls back. Reactor storage writes MUST commit independently of the host transaction. Locks, semaphore tokens and claims MUST be visible to other processes immediately, and execution history MUST survive the host rollback.
- **Database unavailable mid-execution**: Storage operations that fail because the database cannot be reached MUST surface the same way Redis connection failures do today (retried or failed per existing semantics). They MUST never be silently dropped or reported as success.
- **Clock skew between hosts**: Expiry decisions for locks, semaphores and rate-limit windows MUST be consistent across processes running on hosts whose clocks differ.
- **Crashed lock holder**: A lock or semaphore token held by a crashed process MUST become available again once its TTL elapses, as with Redis. Coordination state keeps TTL semantics even though execution history does not expire.
- **Large contexts**: The relational adapter MUST accept every context size the Redis adapter accepts on PostgreSQL and SQLite. On MySQL the limit is half of the server's `max_allowed_packet` (the rest is statement headroom), which operators configure. Above whatever limit applies, contexts MUST raise the same `ContextTooLargeError` rather than being truncated or failing with a driver error.
- **SQLite under concurrent workers**: Write contention MUST surface as a retriable condition and never cause corrupt or lost state. SQLite is documented as suitable for development, tests and single-host use only.
- **No completion-signal channel**: Waiters that rely on completion signals MUST still finish within the documented fallback interval when the relational adapter has no push channel. The signal is a latency optimization, never needed for correctness.
- **Switching adapters with in-flight executions**: Executions in progress in Redis are not moved to the relational store. The documented procedure is to drain in-flight work before switching. After the switch, the relational adapter does not report Redis executions.
- **Documented TTL-expiry outcomes**: Outcomes that the docs tie to expired state (for example map rollback reporting `reason: :context_unavailable` after `context_ttl`) cannot happen under the relational adapter while history is kept. The docs MUST say so per adapter rather than leave a claim that is false for one of them.
- **Unbounded growth of coordination state**: Expired locks, released semaphore tokens and past rate-limit windows MUST NOT pile up in a way that degrades correctness or speed. Only execution history and period markers are kept permanently.
- **Schema drift**: Booting a newer gem against an older schema, or the reverse, MUST fail loudly (Story 2, scenario 3) and never read or write with a mismatched layout.

## Requirements *(mandatory)*

### Functional Requirements

**Adapter selection and packaging**

- **FR-001**: Users MUST be able to select the relational adapter or the Redis adapter through RubyReactor's existing storage configuration. Redis MUST remain the default.
- **FR-002**: The gem MUST NOT declare ActiveRecord, or any database driver, as a runtime dependency. Loading the gem with the Redis adapter MUST NOT load ActiveRecord.
- **FR-003**: Selecting the relational adapter in an app where ActiveRecord is unavailable MUST fail at configuration time with a clear error naming the missing dependency.
- **FR-004**: The relational adapter MUST support PostgreSQL, MySQL and SQLite.
- **FR-005**: Users MUST be able to direct reactor storage to the app's primary database or to a separately configured database connection.
- **FR-006**: When the relational adapter and a non-Redis queue backend are configured, RubyReactor MUST NOT open any connection to a Redis server.

**Behavioral parity**

- **FR-007**: The relational adapter MUST implement every operation of the storage adapter contract: contexts, correlation IDs, async step results, map results, counters, element indexes and rollback records, interrupt resume claims and attempt counts, reactor scanning, locks, semaphores, rate limits, periods, ordered locks, liveness checks and completion signals.
- **FR-008**: Every behavioral claim in `README.md` and `documentation/` MUST hold under the relational adapter, unless the documentation states explicitly that it differs and why. The only allowed differences are those caused by permanent history instead of TTL expiry.
- **FR-009**: Atomicity guarantees that Redis provides today (atomic compare-and-set, single-claim semantics, multi-window rate-limit check-and-increment, exactly-one owner signals) MUST hold under concurrent access from multiple processes.
- **FR-010**: Reactor storage writes MUST commit independently of any application transaction open when they are issued.
- **FR-011**: Coordination state (locks, semaphore tokens, rate-limit windows, liveness locks, ordered-lock heartbeats) MUST keep its TTL semantics. Expiry decisions MUST be consistent across processes regardless of host clock differences.
- **FR-012**: Waiters MUST complete correctly without a push-notification channel, within the documented fallback interval.
- **FR-013**: The built-in RSpec helpers and matchers in `lib/ruby_reactor/rspec` (including storage reset between examples) MUST work unchanged under both adapters.

**History and retention**

- **FR-014**: Under the relational adapter, execution records (context, step results, map results, interrupt history, rollback outcomes, failure details) MUST be kept with no automatic expiry.
- **FR-015**: Period markers MUST be kept permanently under the relational adapter and MUST record the bucket, the claiming execution and the claim time.
- **FR-016**: The relational adapter's sweeper-facing scans (stranded runs, async step results, maps, map rollbacks) MUST be bounded by `context_ttl`, so that recovery matches Redis: work stranded longer than `context_ttl` is never re-enqueued. Dashboard listing and querying MUST NOT be bounded. `context_ttl` MUST NOT be used for anything else under the relational adapter.

**Schema management**

- **FR-017**: The gem MUST ship its relational schema as versioned migrations, with an install path for Rails apps and a documented path for non-Rails ActiveRecord apps.
- **FR-018**: A gem release that changes the schema MUST add new migrations and MUST NOT modify ones already released. Applying them MUST keep existing history.
- **FR-019**: At first storage use, the relational adapter MUST check that the installed schema version matches the one the gem requires. If it does not, it MUST fail with an error naming both versions and the fix, before reading or writing anything.

**Dashboard and querying**

- **FR-020**: Under the relational adapter, the dashboard MUST list all recorded executions with paging, and MUST be able to filter by reactor class, status, time range and an input's key/value equality, alone or combined.
- **FR-021**: Inputs configured as redacted MUST never be shown in plain text in an execution's inputs view, and MUST NOT be usable as filter values. Values a step copies from a redacted input into its own results are out of scope; step arguments are already redacted in the execution trace.
- **FR-022**: Under the Redis adapter, the dashboard MUST keep working as today, except for the FR-021 masking of redacted inputs, which applies to both adapters. It MUST present filters that only the relational adapter supports as unavailable, never as errors.

**Idempotency**

- **FR-023**: Users MUST be able to start a reactor with an idempotency key, scoped per reactor class. A start with a key already recorded MUST return the existing execution's outcome or current status without running steps again.
- **FR-024**: Concurrent starts with the same reactor class and idempotency key MUST result in exactly one execution.
- **FR-025**: Idempotency keys MUST be honored permanently under the relational adapter and within the retention window under Redis, as documented.

**Testing, demo and documentation**

- **FR-026**: The gem test suite MUST select its storage adapter, and for the relational adapter its database, through an environment variable. With the variable unset, it MUST behave as today.
- **FR-027**: Specs that test one adapter's internal mechanics MUST be tagged to run only under that adapter. Wherever the behavior is shared, each MUST have an equivalent covering the same behavior for the other adapter.
- **FR-028**: CI MUST run the gem suite and the `demo_app` suite once for Redis and once per supported database for the relational adapter, against real services.
- **FR-029**: `demo_app` MUST select its storage adapter through an environment variable and MUST include an example reactor, a rake task and a spec that show permanent history, a `:year` period and idempotency keys, per Constitution Principle VI. `docker-compose.yml` MUST provide the services each combination needs.
- **FR-030**: `README.md`, the relevant `documentation/` files and `CHANGELOG.md` MUST describe adapter selection, installation, schema upgrades, per-adapter differences, supported databases (with SQLite's limits), the procedure for switching adapters, and the new idempotency API.

### Key Entities *(include if feature involves data)*

- **Execution**: One reactor run (root, composed child or map element). Holds reactor class, status, inputs (respecting redaction), serialized context, correlation ID, idempotency key, parent/root links, and timestamps. Kept permanently under the relational adapter.
- **Step Result**: The durable outcome of an async step for one execution and step name (dispatched or completed). Written by a worker other than the parent's.
- **Map Operation**: One map step's fan-out. Holds expected element count, completion counter, owner-signal claim, ordering mode, and links to element executions.
- **Map Result Slot**: One element's result, keyed by element index within its map operation.
- **Map Rollback Record**: Rollback progress and per-element outcomes for one map operation (claimed positions, offset, hand-off flag, summary).
- **Interrupt Resume Claim**: The single accepted resume payload and attempt count for one execution and interrupt step.
- **Lock**: An exclusive, TTL-bounded claim on a key held by one owner. Re-entrant across composed reactors.
- **Semaphore**: A named pool with a limit and token-based holders.
- **Rate-Limit Window**: A counter for one key base and one fixed time window.
- **Period Marker**: A permanent record that a key base's period bucket was claimed, by which execution, and when.
- **Ordered-Lock Sequence**: Per-key nonce assignment, last-completed nonce, epoch and heartbeat for strict sequential runs.
- **Schema Version**: The schema version installed in the database, compared with the one the gem requires.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of the gem's adapter-agnostic specs pass under the relational adapter on each of PostgreSQL, MySQL and SQLite. 100% of the existing specs still pass under Redis.
- **SC-002**: Every behavioral claim in `README.md` and `documentation/` is either covered by a passing spec under both adapters, or documented explicitly as differing by adapter. There are zero undocumented differences.
- **SC-003**: 100% of `demo_app` reactor specs and `demo:` rake tasks pass in CI under each adapter/database combination.
- **SC-004**: The gem's runtime dependency list gains zero entries. An existing Redis user who upgrades with no configuration change sees zero behavioral differences in their test suite. There are two intended exceptions, both recorded in the CHANGELOG: the dashboard masks redacted inputs (FR-021), and a Redis period marker stores the claiming execution's id instead of `"1"`, which no public API exposed.
- **SC-005**: With the relational adapter and the ActiveJob backend, the full `demo:` acceptance suite completes with no Redis server reachable.
- **SC-006**: In a stress test of 1,000 contended acquisitions across at least 4 worker processes, locks, semaphores, rate limits and ordered locks show 0 violations (no double grant, no limit overrun, no out-of-order run) on PostgreSQL and MySQL.
- **SC-007**: With 100,000 recorded executions, a dashboard filter by input value returns its first page in under 2 seconds on PostgreSQL and MySQL.
- **SC-008**: On one machine with the same queue backend (ActiveJob), the `demo_app` reactor suite under the relational adapter on PostgreSQL takes no more than 2× its wall-clock time under Redis. This is a release-checklist measurement, not a per-PR gate.
- **SC-009**: Upgrading a database holding history through a shipped schema migration keeps 100% of existing execution records readable.
- **SC-010**: An execution that finished more than one year earlier (simulated time) is still fully viewable, and a `:year` period claimed at the start of a year still deduplicates runs on the year's last day.

## Assumptions

- Host apps that choose the relational adapter already depend on ActiveRecord and a supported database driver. The gem relies on them being present and does not install them.
- Redis stays the default adapter, and existing Redis configuration keeps working unchanged. The `redis` and `sidekiq` gems keep their current status in the gemspec; changing that is out of scope.
- Rails apps use a generator-based install. Non-Rails ActiveRecord apps get documented manual steps to create and upgrade the schema.
- Moving existing Redis data into the relational store is out of scope. Users drain in-flight executions before switching.
- Routing different features to different adapters (for example, coordination in Redis and history in the database) is out of scope. It is planned as a later feature. This feature keeps the adapter contract able to support it but does not build it.
- The gem deletes no history automatically. Operators who need to prune old executions use their own database tools. A purge helper is out of scope.
- Idempotency keys apply when a reactor run starts, scoped per reactor class. The existing, undocumented `idempotency_key:` parameter on `continue` is unchanged; duplicate resumes are already rejected by interrupt resume claims.
- Advanced dashboard filtering is a relational-adapter capability. The Redis dashboard keeps its current scan-based listing.
- Input-value filtering supports equality on top-level scalar inputs whose value is 255 characters or fewer. Range, full-text and nested-path queries, and filtering on longer or non-scalar values, are out of scope.
- This feature conflicts with the project constitution: Technical Constraints say Redis is "Required for state persistence, locks…", and Principle III says Redis must be reachable for the test suite. The constitution needs amending (via `/speckit-constitution`) to make the configured real storage backend the requirement before this feature merges.
