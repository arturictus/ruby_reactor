# Implementation Plan: Step Input Contracts

**Branch**: `step_validations` | **Date**: 2026-09-10 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/002-step-input-contracts/spec.md`

## Summary

Move validation out of the reactor and into the unit of work. A step class declares its own
inputs with `input :name, :type, **predicates`; an inline step declares the same lines inside
an `inputs do ... end` block. The reactor's `argument` keeps dependency wiring and value
mapping and loses rule declaration for any step that owns a contract — attempting both fails
at the `step` macro rather than producing two overlapping rule sets at run time.

Enforcement for class steps lives in a `run` wrapper prepended onto the step's singleton
class, which covers the executor, the async worker, and direct invocation with one mechanism
and reuses the library's existing `Error::InputValidationError` protocol (raise → rollback →
`build_validation_failure` → `have_validation_error`). Inline contracts compile to the
existing `args_validator` and close the async worker's missing validation call.

Two supporting corrections ship with it: an unwired declared input resolves from a same-named
reactor input (checked before execution, never from another step's result), and falsey values
stop being lost in transit — `Context#get_input`/`#get_result` and `Template::Result#fetch`
currently turn a supplied `false` into `nil`, which contracts would escalate into a spurious
"must be filled" failure.

Design decisions and the evidence behind them: [research.md](./research.md).

## Technical Context

**Language/Version**: Ruby >= 3.0.0

**Primary Dependencies**: dry-validation ~> 1.10 (schema construction; already a hard gem
dependency), sidekiq ~> 7.0 (async step path), redis ~> 5.0, zeitwerk ~> 2.6

**Storage**: Redis (unchanged by this feature — contracts are compile-time declarations;
resolved arguments already round-trip through `ContextSerializer`)

**Testing**: RSpec with real Redis (constitution III). Feature specs under
`spec/ruby_reactor/dsl/` and `spec/ruby_reactor/`; acceptance via `demo_app/` rake tasks run
through `docker compose run`.

**Target Platform**: Ruby library (gem), sync and Sidekiq-backed async execution

**Project Type**: Library / DSL

**Performance Goals**: Validation cost is per-step-execution and already paid today for
reactor-declared rules; no measurable regression. Contract compilation happens once at class
definition. `validate_definition!` is memoized per reactor class.

**Constraints**: Public API is SemVer-governed — additive DSL (MINOR); no existing reactor may
change behavior except the falsey-value fix (PATCH-class bug fix, changelog note required).
dry-validation stays the only validation engine.

**Scale/Scope**: ~8 library files touched, 1 new file, plus demo-app artifacts and README.
No new gem dependency.

## Constitution Check

*GATE: passed before Phase 0. Re-checked after Phase 1 design — see bottom of this section.*

| Principle | Assessment |
|---|---|
| **I. Gem-First Design** | ✅ Entirely inside `lib/`. No host coupling, no monkey-patching. The Sidekiq-facing change (`StepWorker`) is inside the existing adapter boundary. |
| **II. Saga Pattern Integrity** | ✅ Validation failures raise `Error::InputValidationError`, which `handle_execution_error` already routes through `rollback_completed_steps` before building the failure. Compensation semantics are inherited, not re-implemented. Validation runs *before* the step body, so a rejected step produces no side effect to compensate. |
| **III. Test-First with Real Infrastructure** | ✅ Red-Green-Refactor per task. The async-worker validation gap (research Finding 2) is exercised against real Redis + Sidekiq, not `Sidekiq::Testing.inline!`. |
| **IV. Observability by Default** | ✅ Failures carry reactor name, step name, redacted inputs, and field errors — `build_validation_failure` already assembles this; D3 adds the missing step attribution for class steps. FR-015 keeps `redact:` declarable on a step's own contract. |
| **V. Simplicity and SemVer** | ✅ MINOR: `input` on step classes and `inputs do` in step blocks are additive; reactor-declared rules keep working (D9 deprecation, not removal). The conflict error (D5) can only fire on code written after this release, since declaring a contract on a step class is not possible today. Falsey fix is a bug fix with a changelog note. Two enforcement mechanisms are justified in Complexity Tracking. |
| **VI. Demo-App Proof of Feature** | ✅ Planned as blocking work, not follow-up: example reactor + `demo:` rake task + spec using only the shipped matchers + `docker compose run` acceptance. `have_validation_error` already exists, so no matcher extension is expected — if a task finds an assertion it cannot express, the matcher is added to `lib/ruby_reactor/rspec/` in the same change. |

**Post-design re-check**: no new violations. The design adds no new dependency, no new
storage primitive, and no new failure shape — it routes a new declaration site into the
error protocol the library already has. The one item carried to Complexity Tracking is the
dual enforcement mechanism.

## Project Structure

### Documentation (this feature)

```text
specs/002-step-input-contracts/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0 — current-state findings and design decisions
├── data-model.md        # Phase 1 — contract/declaration entities and lifecycle
├── quickstart.md        # Phase 1 — how to run and verify the feature
├── contracts/
│   └── dsl-surface.md   # Phase 1 — public DSL, errors, introspection API
├── checklists/
│   └── requirements.md  # Spec quality checklist (complete)
└── tasks.md             # Phase 2 — /speckit-tasks output, NOT created here
```

### Source Code (repository root)

```text
lib/ruby_reactor/
├── step.rb                          # + `input` DSL, contract storage/inheritance,
│                                    #   introspection, singleton `run` wrapper (D1, D3)
├── step/
│   └── input_contract.rb            # NEW — declaration list, schema compilation,
│                                    #   defaults, redaction, inheritance merge
├── dsl/
│   ├── step_builder.rb              # + `inputs do` block (D2); conflict + unknown-argument
│   │                                #   errors at build time (D5)
│   ├── reactor.rb                   # + `validate_definition!` (D6), name-based
│   │                                #   fallback wiring (D7)
│   └── validation_helpers.rb        # reused unchanged by the step-side builder
├── executor/
│   └── step_executor.rb             # stamp `step_name` on re-raised validation errors (D3)
├── step_worker.rb                   # validate inline-step args; InputValidationError branch (D4)
├── context.rb                       # presence-aware get_input / get_result (D8)
├── template/result.rb               # presence-aware nested fetch (D8)
├── utils/
│   └── fetch_indifferent.rb         # NEW — the one shared presence-aware lookup (D8)
├── reactor.rb                       # call validate_definition! before execution (D6)
└── rspec/
    └── test_subject.rb              # call validate_definition! from test_reactor (D6)

spec/ruby_reactor/
├── dsl/step_input_contract_spec.rb        # NEW — declaration, inheritance, introspection
├── dsl/step_contract_conflict_spec.rb     # NEW — D5 errors, D6 satisfiability
├── step_contract_enforcement_spec.rb      # NEW — all execution paths incl. async worker
└── falsey_input_resolution_spec.rb        # NEW — FR-023 across inputs, results, paths

demo_app/
├── app/reactors/validated_signup_reactor.rb   # NEW — contract-owning step, pass + fail path
├── lib/tasks/demo_reactors.rake               # + demo:validated_signup
└── spec/reactors/validated_signup_reactor_spec.rb  # NEW — shipped matchers only

README.md                            # class-step form primary, inline equivalent, migration
CHANGELOG.md                         # Features + Bug Fixes entries
```

**Structure Decision**: The gem's existing layout is kept as-is. Two new library files only —
`step/input_contract.rb` (the declaration object the spec's Key Entities describe) and
`utils/fetch_indifferent.rb` (one helper, three call sites). Everything else is an edit to the
file that already owns the concern.

## Phase 2 outline (for `/speckit-tasks`)

Dependency-ordered, each block independently testable:

1. **Falsey resolution (FR-023)** — `fetch_indifferent` + three call sites + spec. Independent
   of everything else; land first so contract work builds on correct presence semantics.
2. **Contract declaration (US1, FR-001/002/013/014/015)** — `InputContract`, `Step#input`,
   inheritance, introspection. No enforcement yet.
3. **Enforcement (US1, FR-003/004/022)** — prepended `run` wrapper, step-name stamping,
   worker path. Covers class steps on every execution path.
4. **Reactor-side split (US2, FR-005/006/018)** — conflict and unknown-argument errors at the
   `step` macro.
5. **Inline contracts (US3, FR-007)** — `inputs do` block → `args_validator`, worker
   validation call, equivalence spec against the class form.
6. **Wiring resolution (US4, FR-008/020/021)** — `validate_definition!`, name-based fallback,
   invocation from `run`/`call`/`test_reactor`.
7. **Back-compat + deprecation (US5, FR-010/011)** — existing-suite green, one-time notices.
8. **Docs + demo (FR-016/017)** — README, CHANGELOG, demo reactor + rake + spec, docker
   acceptance run.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|--------------------------------------|
| Two enforcement mechanisms — prepended `run` for class steps (D3), `args_validator` for inline steps (D4) | An inline step has no class to prepend to, and a class step must validate on paths the reactor does not control (`StepWorker#execute_step_body`, direct invocation). | Putting every contract into `args_validator` leaves the async worker path and direct invocation unvalidated (research Finding 2), and re-centralizes in the reactor exactly what this feature moves into the step. Both mechanisms raise the same error class through the same handler, so the observable behavior is one protocol, and an equivalence spec pins them together. |
| `validate_definition!` runs at first execution rather than at class load (D6) | The satisfiability check needs the reactor's complete input list, which is not available while the class body is still executing, and there is no registry of user reactor classes to sweep at boot (research Finding 7). | `TracePoint(:end)` to detect the end of a class body is unreadable and breaks on reopened classes; requiring `input` before `step` silently breaks valid existing reactors. The user-visible property is preserved — the reactor fails before step one runs, not on the run that first reaches the step. |
