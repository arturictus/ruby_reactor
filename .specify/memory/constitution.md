<!--
SYNC IMPACT REPORT
==================
Version change: 1.1.0 → 1.2.0 (MINOR: Principle VI expanded with a 4th requirement —
  docker-compose.yml currency + docker-run acceptance tests)

Modified principles:
  - Principle VI: Demo-App Proof of Feature — added requirement 4, "Docker acceptance
    run" (docker-compose.yml MUST track demo_app's services; demo: rake tasks are the
    project's acceptance suite, runnable via `docker compose run`)

Added sections: none (existing Principle VI section extended)

Removed sections: none

Templates checked:
  - .specify/templates/plan-template.md   ✅ Constitution Check gate is generic ("Gates determined
                                             based on constitution file") — no edit required
  - .specify/templates/spec-template.md   ✅ No principle-specific content — no edit required
  - .specify/templates/tasks-template.md  ✅ Already covers demo-app polish tasks — no edit required
  - .specify/templates/checklist-template.md ✅ Generic — no edit required
  - .specify/extensions.yml               ✅ No before/after_constitution hooks registered

Deferred TODOs: none
-->

# RubyReactor Constitution

## Core Principles

### I. Gem-First Design

RubyReactor is a Ruby gem published to RubyGems. Every feature MUST be designed
as part of the gem's public API — self-contained, independently loadable, and
free of host-application coupling. New capabilities MUST ship via `lib/` and be
reachable through `require "ruby_reactor"` without requiring application-level
monkey-patching. Optional integrations (Sidekiq, OpenTelemetry) MUST be isolated
behind adapter modules so the gem remains usable in sync-only or minimal
environments.

**Rationale**: A gem that cannot be required cleanly, or that bleeds host
concerns into its core, is not a gem — it is a Rails engine in disguise.
Keeping gem boundaries honest protects downstream consumers.

### II. Saga Pattern Integrity (NON-NEGOTIABLE)

Every workflow defined with RubyReactor MUST support compensation. Steps MUST
declare rollback logic where side effects are produced. DAG-based dependency
resolution governs execution order — no step may run before its declared
dependencies complete. Interrupts (pause/resume) MUST be first-class, not
bolted on. Partial execution without a recovery path (durability or compensation)
is forbidden.

**Rationale**: The Saga pattern's value is atomicity-like guarantees without
distributed transactions. Violating it — e.g., skipping compensation or allowing
orphaned steps — destroys the core promise and corrupts application state.

### III. Test-First with Real Infrastructure

RSpec is the mandatory test framework. Tests MUST be written and confirmed
failing before implementation begins (Red-Green-Refactor). Redis MUST be
reachable for the test suite — mocking Redis or Sidekiq state is forbidden
for integration and contract tests. The in-memory Sidekiq testing mode
(`Sidekiq::Testing.inline!`) is acceptable only for unit-level step logic,
never for async orchestration paths.

**Rationale**: We were burned by mock/real divergence in async and locking
paths. Real Redis surfaces timing, serialization, and TTL bugs that mocks
hide. The spec_helper enforces Redis availability at suite start for this
reason.

### IV. Observability by Default

Every failure MUST carry: reactor name, step name, redacted inputs, and
failure reason. OpenTelemetry instrumentation MUST be available via middleware
without requiring it as a hard dependency. The web dashboard MUST remain
current with the reactor state model. Structured logging is required for all
async execution paths — log lines MUST be machine-parseable (key=value or JSON).

**Rationale**: Async distributed workflows are black boxes without
observability. Operators need to reconstruct what happened and why from logs
and dashboards alone, especially after crash recovery.

### V. Simplicity and Semantic Versioning

YAGNI governs design: add the abstraction when a second real use case exists,
not before. Complexity MUST be justified in the PR. SemVer is strictly
enforced: MAJOR for any breaking public API change, MINOR for backward-compatible
additions, PATCH for fixes and clarifications. Breaking changes MUST include a
migration note in CHANGELOG.md.

**Rationale**: RubyReactor is a library used in production applications. A
surprise breaking change in a MINOR bump costs downstream teams debugging time
they did not budget for. Simplicity keeps the library auditable and the
upgrade path predictable.

### VI. Demo-App Proof of Feature (NON-NEGOTIABLE)

Every user-facing feature or public API change MUST ship with a runnable example
in `demo_app/`. Three artifacts are required together — a change is incomplete if
any one is missing:

1. **Example reactor**: a reactor (or step) demonstrating the feature MUST live in
   `demo_app/app/reactors/`, one file per reactor, named `<snake_case>_reactor.rb`
   matching its class name. The example MUST exercise the feature end to end —
   including its failure and compensation path where the feature has one — and MUST
   use class-based step definitions per the Development Workflow rule.
2. **Rake entry**: the example MUST be registered as a task in
   `demo_app/lib/tasks/demo_reactors.rake` under the `demo:` namespace, with a `desc`
   line describing what it demonstrates, and depending on `[:environment, :flush_redis]`
   so each run starts from clean Redis state. The task MUST print observable outcomes
   (success, failure, background dispatch, pause) so an operator can verify behavior
   without a debugger.
3. **Spec**: a matching spec MUST live at
   `demo_app/spec/reactors/<reactor>_spec.rb`, declared `type: :reactor`, and MUST use
   **only** the built-in test surface exported by `lib/ruby_reactor/rspec.rb` — the
   helpers (`test_reactor`, `drain_async_jobs`), the `TestSubject` API
   (`mock_step`, `failing_at`, `map`, `composed`, `async_step`, `resume`,
   `step_result`, `ensure_executed!`), and the matchers (`be_success`, `be_failure`,
   `have_run_step(...).after(...)`, `have_retried_step`, `have_validation_error`,
   `be_paused`, `be_paused_at`, `have_ready_interrupts`, `be_halted`, `be_skipped`,
   `be_locked`, `have_available_tokens`, `have_held_tokens`, `have_rate_limit_count`,
   `be_period_marked`, and the ordered-lock matchers).

Hand-rolled test scaffolding is forbidden in `demo_app/spec/reactors/`: no direct
`RubyReactor::Executor`/`Storage` calls, no bespoke Sidekiq draining, no manual Redis
assertions, no stubbing of reactor internals. If an assertion cannot be expressed with
the built-in surface, the missing matcher or helper MUST be added to
`lib/ruby_reactor/rspec/` in the same change — extending the shared test API, not
bypassing it.

4. **Docker acceptance run**: `docker-compose.yml` MUST stay current with `demo_app`'s
   runtime dependencies (Redis, Sidekiq, the Rails service itself) so that
   `docker compose run --rm demo-app bin/rails demo:<task>` runs the new rake task
   end to end against real Redis, with no manual setup beyond `docker compose up`.
   A new demo service or environment variable required by a feature MUST be added to
   `docker-compose.yml` in the same change. The `demo:` rake tasks in
   `demo_app/lib/tasks/demo_reactors.rake` constitute the project's acceptance test
   suite for user-facing behavior — CI or a release checklist MAY invoke them via
   `docker compose run` to confirm the demo still passes before a MINOR/MAJOR release.

**Rationale**: `demo_app/` is the only place the gem is consumed the way users consume
it. An example that is written but never listed is never run; a spec written with
private internals passes while the public API is broken. Forcing every feature through
the public reactor DSL, a runnable rake task, and the shipped matchers means the
documented API, the demo, and the test surface are validated by the same change — and
gaps in the matcher library surface as work instead of as workarounds.

## Technical Constraints

- **Ruby**: >= 3.0.0 required. No polyfills for older Rubies.
- **Sidekiq**: Core async dependency. Workers live in `lib/ruby_reactor/sidekiq_workers/`.
- **Redis**: Required for state persistence, locks, semaphores, rate limits, and
  periods. The gem does NOT manage Redis connections — callers provide them.
- **dry-validation**: Input validation DSL. Schema definitions stay inside the
  reactor/step DSL, not scattered across application code.
- **OpenTelemetry**: Optional instrumentation via the middleware stack
  (`lib/ruby_reactor/open_telemetry.rb`). MUST NOT be a hard dependency.
- **RuboCop**: Style enforced via `rubocop-rspec` and `rubocop-rake`. All
  commits MUST pass `bundle exec rubocop` without `--disable-pending-cops`.

## Development Workflow

- Feature branches target `main`. PRs MUST pass CI (RSpec + RuboCop) before merge.
- Releases are managed by release-please. Version bump lives in
  `lib/ruby_reactor/version.rb`. Do not manually edit the version in gemspec.
- New features MUST update `README.md` documentation and add entries to
  `CHANGELOG.md` under the correct semantic heading (`Features`, `Bug Fixes`,
  `documentation`).
- Class-based step definitions are the preferred authoring style (not inline
  lambdas). Documentation and examples MUST reflect this.
- The `demo_app/` directory serves as a living integration example. Changes to
  public API surface MUST be reflected there per Principle VI — example reactor in
  `demo_app/app/reactors/`, rake task in `demo_app/lib/tasks/demo_reactors.rake`,
  and a spec in `demo_app/spec/reactors/` using only the built-in RSpec matchers
  and helpers from `lib/ruby_reactor/rspec.rb`.
- PR reviews MUST reject any feature change whose demo example is missing, unlisted
  in the rake file, or tested with hand-rolled scaffolding instead of the shipped
  matcher library.
- `docker-compose.yml` MUST be kept current with `demo_app`'s services (Redis,
  Sidekiq, Rails) so `docker compose up` and `docker compose run --rm demo-app
  bin/rails demo:<task>` are the supported way to run the `demo:` rake tasks as
  acceptance tests, with no host-side Ruby/Redis setup required.

## Governance

This constitution supersedes all other informal practices. Amendments require:

1. A PR updating this file with rationale.
2. Version bump per the SemVer policy in Principle V.
3. Consistency propagation: update all `.specify/templates/` files that reference
   amended principles before the PR merges.

All PR reviews MUST include a Constitution Check verifying the change does not
violate any principle. Complexity that appears to violate a principle MUST be
justified in the `Complexity Tracking` table of the plan.

Compliance review: at each MINOR or MAJOR gem release, confirm this constitution
still accurately reflects the codebase and update as needed.

**Version**: 1.2.0 | **Ratified**: 2025-10-02 | **Last Amended**: 2026-09-09
