# Implementation Plan: Step-Scoped Coordination

**Branch**: `step_validations` | **Date**: 2026-09-10 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/003-step-lock-declarations/spec.md`

## Summary

Let a step declare its own coordination — exclusivity, concurrency ceiling, rate ceiling,
dedup window, strict ordering — keyed on the step's own resolved arguments, so one step of a
workflow can be serialized without serializing the workflow.

The declaration surface already exists: `Dsl::Lockable`'s five macros are a self-contained
module whose only contract is "a key proc that receives a hash". Steps host it unchanged and
pass their arguments where the reactor passes its inputs. Enforcement is a `StepCoordination`
object the executor wraps around the step body, in the same fixed order the reactor uses.

Contention parks the execution rather than failing it, reusing `requeue_job_for_step_retry` —
which already persists the context with `current_step` set and re-enqueues — with contention
attempts counted separately from failure retries. Synchronously there is no queue to park
into, so that path waits then fails.

Re-entrancy reuses every existing nested-workflow primitive unchanged: holds owned by the root
context id, the adapter's nesting count, the `held_lock_keys` registry, and the dispatch-time
deadlock guard — which already covers step holds, since it reads that registry.

Design decisions and evidence: [research.md](./research.md).

## Technical Context

**Language/Version**: Ruby >= 3.0.0

**Primary Dependencies**: redis ~> 5.0 (every primitive is Redis-backed), sidekiq ~> 7.0
(the park-and-retry path), zeitwerk ~> 2.6. No new dependency.

**Storage**: Redis. Step holds use the same key spaces, TTLs, and Lua primitives as reactor
holds (`storage/redis_locking.rb`, `storage/redis_ordered_locking.rb`). New per-step state is
confined to `context.private_data` (contention counter, per-step ordered-lock nonce), which
already round-trips through `ContextSerializer`.

**Testing**: RSpec against real Redis (constitution III). Concurrency claims need genuine
parallelism — overlap detection across processes/threads, not mocked timing. The park-and-
retry path must be exercised with a real Sidekiq worker, not `Sidekiq::Testing.inline!`.

**Target Platform**: Ruby library, sync and Sidekiq-backed async execution

**Project Type**: Library / DSL

**Performance Goals**: A step declaring nothing pays one nil check per step. A step declaring
coordination pays the same Redis round-trips the reactor-level equivalent pays today, moved
from once-per-run to once-per-step-execution. The point of the feature is that the critical
section shrinks, so end-to-end throughput under contention should improve, not regress.

**Constraints**: Additive and SemVer-MINOR — no existing reactor changes behavior. Coordination
must never be held across a process hand-off. The critical section must stay minimal:
acquisition happens after guards and after argument validation.

**Scale/Scope**: ~10 library files touched, 2-3 new, plus demo-app artifacts and docs. The
ordered-lock phase is roughly the weight of the other four primitives combined.

## Constitution Check

*GATE: passed before Phase 0. Re-checked after Phase 1 design — see below.*

| Principle | Assessment |
|---|---|
| **I. Gem-First Design** | ✅ Entirely inside `lib/`. Redis and Sidekiq usage stays behind the existing adapter and router boundaries; callers still provide their own connections. |
| **II. Saga Pattern Integrity** | ✅ The strongest alignment in this feature. Coordination is re-taken for compensate/undo (FR-024), so rollback of a protected operation is protected too — closing a race the reactor-level lock leaves open whenever rollback outlives the reactor's own hold. Contention parks rather than fails, so routine contention never triggers spurious compensation. Nothing changes which steps run or in what order (FR-014). |
| **III. Test-First with Real Infrastructure** | ✅ Non-negotiable here: every claim is a concurrency claim. Real Redis, real Sidekiq for the park path. `Sidekiq::Testing.inline!` is explicitly wrong for this feature — it re-enters the worker synchronously inside the holding frame (the reason `acquire_context_lock` skips itself under it, `executor.rb:470`). |
| **IV. Observability by Default** | ✅ FR-028/FR-029. Events carry the step name; the dashboard's coordination view learns step-level state; a contention-parked execution is distinguishable from a failed one, reusing the `:snooze_reactor` precedent that already keeps snooze rounds from reading as phantom failures. |
| **V. Simplicity and SemVer** | ⚠️ Justified. MINOR and fully additive — a step declaring nothing is unaffected. But the scope is five primitives where the request was one, and YAGNI applies to four of them; the step-level ordered lock in particular invents a guarantee (order-of-arrival) weaker than the one its name implies. Recorded in Complexity Tracking, sequenced last, and flagged as the first thing to cut. |
| **VI. Demo-App Proof of Feature** | ✅ Blocking work: example reactor + `demo:` rake task + spec using only shipped matchers + `docker compose run`. `be_locked`, `have_available_tokens`, `have_held_tokens`, `have_rate_limit_count`, `be_period_marked`, and the ordered-lock matchers already exist; step-scoped assertions are expected to need at least one addition (a step-attributed hold), which goes into `lib/ruby_reactor/rspec/` in the same change rather than being worked around. |

**Post-design re-check**: no new violations. No new dependency, no new storage primitive, no
new failure shape — the design routes a second declaration site into mechanisms that already
exist. The two carried items are scope (five primitives) and the ordered-lock guarantee gap.

## Project Structure

### Documentation (this feature)

```text
specs/003-step-lock-declarations/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0 — current-state findings and design decisions
├── data-model.md        # Phase 1 — declaration/hold entities and lifecycle
├── quickstart.md        # Phase 1 — how to run and verify
├── contracts/
│   └── dsl-surface.md   # Phase 1 — public DSL, semantics per primitive, errors
├── checklists/
│   └── requirements.md  # Spec quality checklist (complete)
└── tasks.md             # Phase 2 — /speckit-tasks output, NOT created here
```

### Source Code (repository root)

```text
lib/ruby_reactor/
├── dsl/
│   ├── lockable.rb                   # unchanged module, now also hosted by steps
│   └── step_builder.rb               # + the five macros for inline steps; refuse on
│                                     #   interrupt steps (D6); config onto StepConfig
├── step.rb                           # + host Lockable macros; introspection (D1)
├── executor/
│   ├── step_coordination.rb          # NEW — acquire/release in fixed order, contention
│   │                                 #   handling, park decision (D2, D3, D4)
│   ├── step_executor.rb              # wrap the step body in StepCoordination
│   ├── retry_manager.rb              # contention requeue + separate contention counter (D4)
│   └── compensation_manager.rb       # re-take exclusion primitives for compensate/undo (FR-024)
├── step/
│   └── async_reactor_step.rb         # deadlock guard also covers async_step dispatch (D5)
├── step_worker.rb                    # coordination around the worker-side step body
├── retry_context.rb                  # + contention attempt counter
├── web/coordination_serializer.rb    # + step-level coordination state (D9)
└── rspec/matchers.rb                 # + step-attributed hold assertions as needed

spec/ruby_reactor/
├── step_coordination/lock_spec.rb           # NEW — US1, US2 (real concurrency)
├── step_coordination/contention_spec.rb     # NEW — US3 both paths, bounded retries
├── step_coordination/reentrancy_spec.rb     # NEW — US4 incl. dispatch refusal
├── step_coordination/primitives_spec.rb     # NEW — US5, one per primitive
├── step_coordination/rollback_spec.rb       # NEW — US6
└── step_coordination/inline_spec.rb         # NEW — US8 equivalence

demo_app/
├── app/reactors/step_lock_demo_reactor.rb        # NEW — serialized, contended, compensated
├── lib/tasks/demo_reactors.rake                  # + demo:step_lock
└── spec/reactors/step_lock_demo_reactor_spec.rb  # NEW — shipped matchers only

documentation/locks_and_semaphores.md   # step-scoped forms, when to prefer which
README.md, CHANGELOG.md
```

**Structure Decision**: Existing layout kept. One new library file carries the feature
(`executor/step_coordination.rb`); everything else is an edit to the file that already owns
the concern. Specs get a `step_coordination/` directory because they are concurrency tests
with shared harness needs, not unit tests scattered across existing files.

## Phase 2 outline (for `/speckit-tasks`)

Dependency-ordered. Phases 1-6 deliver US1-US4 and US6-US8 in full.

1. **Declaration surface** — host `Lockable` on `Step` and `StepBuilder`, introspection,
   refuse on interrupt steps. No enforcement yet.
2. **Exclusive lock enforcement (US1, US2)** — `StepCoordination` around the step body,
   acquire/release, keep-alive, guard skip, key-computation failure. Real-concurrency specs.
3. **Re-entrancy (US4)** — root-context owner, registry push/pop, `async_step` dispatch guard.
4. **Contention (US3)** — requeue park, contention counter and ceiling, sync wait-then-fail.
5. **Rollback (US6)** — re-take exclusion primitives for compensate/undo; verify rate/dedup are
   not applied.
6. **Remaining narrowing primitives (US5 partial)** — semaphore, rate limit, period-skips-step.
7. **Observability + inline steps (US7, US8)** — events, dashboard, matcher additions, inline
   equivalence.
8. **Step-level ordered lock (US5 remainder)** — per-step nonce, heartbeat, advance-on-terminal,
   strict chain skip. Last, and separable: see Complexity Tracking.
9. **Docs + demo** — `documentation/locks_and_semaphores.md`, README, CHANGELOG, demo reactor +
   rake + spec, docker acceptance run.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|--------------------------------------|
| Five primitives at step level where the request named one (Principle V / YAGNI) | Explicit user decision after being shown the narrower option. Parity means an author never has to ask which primitives "work" on a step. | Shipping `with_lock` alone covers the stated use case and every acceptance scenario in US1-US4. It was offered and declined. The four extra primitives are sequenced after the core so the schedule can still absorb them being cut. |
| Step-level ordered lock provides a weaker guarantee than its reactor-level namesake | Included in the user's "all five" decision. Sequencing at step arrival is still useful for a step that sits first in its reactor, where arrival order equals enqueue order. | The reactor-level guarantee cannot be reproduced: the nonce would have to be assigned at enqueue, but the key expression reads arguments that do not exist until the step is reached (research Finding 5). Mitigation is documentation on the macro plus a demo that shows arrival ordering explicitly — not a silent redefinition of the word "ordered". |
| Contention behaves differently in a worker (park) than synchronously (wait, then fail) | Direct consequence of the chosen park-and-retry behavior; a synchronous run has no queue to park into. | Failing on both paths is simpler and was the recommended option; it was declined. `contention_wait` already encodes this exact split for reactor-level holds, so the divergence is inherited rather than invented, and it is one branch in one method. |
