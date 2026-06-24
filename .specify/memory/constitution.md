<!--
SYNC IMPACT REPORT
==================
Version change: [unset] → 1.0.0 (MINOR: initial constitution, all principles defined from scratch)

Modified principles: N/A (first ratification)

Added sections:
  - Core Principles (5 principles)
  - Technical Constraints
  - Development Workflow
  - Governance

Templates checked:
  - .specify/templates/plan-template.md   ✅ Constitution Check gate present, no update needed
  - .specify/templates/spec-template.md   ✅ Aligned with Saga/library constraints
  - .specify/templates/tasks-template.md  ✅ Task phases align with Red-Green workflow

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
  public API surface MUST be reflected there.

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

**Version**: 1.0.0 | **Ratified**: 2025-10-02 | **Last Amended**: 2026-06-24
