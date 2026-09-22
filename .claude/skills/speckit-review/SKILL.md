---
name: "speckit-review"
description: "Review the code changes produced by /speckit-implement against RubyReactor's runtime invariants: saga unwind/compensation/undo, retry semantics, async isolation, lock safety without deadlock, validation ordering, and the behavioral claims made in README/documentation."
argument-hint: "Optional: review scope (e.g. 'locks only', a path, or a git ref to diff against)"
compatibility: "Requires spec-kit project structure with .specify/ directory and a git repository"
metadata:
  author: "project"
user-invocable: true
disable-model-invocation: false
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty). Treat it as a scope
narrowing hint only — it MAY reduce which files are inspected, it MUST NOT disable any gate
below for files that remain in scope.

## Pre-Execution Checks

**Check for extension hooks (before review)**:

- Check if `.specify/extensions.yml` exists in the project root.
- If it exists, read it and look for entries under the `hooks.before_review` key
- If the YAML cannot be parsed or is invalid, skip hook checking silently and continue normally
- Filter out hooks where `enabled` is explicitly `false`. Treat hooks without an `enabled` field as enabled by default.
- For each remaining hook, do **not** attempt to interpret or evaluate hook `condition` expressions:
  - If the hook has no `condition` field, or it is null/empty, treat the hook as executable
  - If the hook defines a non-empty `condition`, skip the hook and leave condition evaluation to the HookExecutor implementation
- When constructing slash commands from hook command names, replace dots (`.`) with hyphens (`-`). For example, `speckit.git.commit` → `/speckit-git-commit`.
- For each executable hook, output the following based on its `optional` flag:
  - **Optional hook** (`optional: true`):

    ```text
    ## Extension Hooks

    **Optional Pre-Hook**: {extension}
    Command: `/{command}`
    Description: {description}

    Prompt: {prompt}
    To execute: `/{command}`
    ```

  - **Mandatory hook** (`optional: false`):

    ```text
    ## Extension Hooks

    **Automatic Pre-Hook**: {extension}
    Executing: `/{command}`
    EXECUTE_COMMAND: {command}

    Wait for the result of the hook command before proceeding to the Goal.
    ```

- If no hooks are registered or `.specify/extensions.yml` does not exist, skip silently

## Goal

Review the **code changes** made for the current feature (normally right after
`/speckit-implement`) and decide whether they are safe to merge. The review answers one
question per gate, with file/line evidence, and ends in a single verdict: `PASS`,
`PASS WITH FINDINGS`, or `BLOCKED`.

This command is **read-only**. It MUST NOT edit source, specs, docs, `tasks.md`, or git
state. Remediation is handed off to `/speckit-converge` (append tasks) or
`/speckit-implement` (fix), not performed here.

It differs from its neighbours:

- `/speckit-analyze` → consistency **between artifacts** (spec/plan/tasks).
- `/speckit-converge` → what the artifacts demand that the code does **not yet do**.
- `/speckit-review` (this one) → whether the code that now exists is **correct, safe, and
  honest** at runtime — saga unwind, retries, async isolation, locks, validation, and the
  claims the docs make about all of it. Constitution/process compliance is out of scope
  here; `/speckit-plan` and `/speckit-converge` already cover it.

## Execution Steps

### 1. Establish Review Scope

Run `.specify/scripts/bash/check-prerequisites.sh --json --require-tasks --include-tasks`
from repo root and parse JSON for FEATURE_DIR and AVAILABLE_DOCS. Derive:

- SPEC = FEATURE_DIR/spec.md, PLAN = FEATURE_DIR/plan.md, TASKS = FEATURE_DIR/tasks.md

These are context for *what the change was meant to do* — the gates below judge the code,
not the artifacts.

If the prerequisites script fails (no active feature), do **not** stop: fall back to a
pure diff review and say so in the report header — none of the gates below require spec
artifacts.

Compute the change set:

```bash
git rev-parse --abbrev-ref HEAD
git merge-base HEAD main
git diff --stat $(git merge-base HEAD main)...HEAD
git diff $(git merge-base HEAD main)...HEAD
git status --porcelain          # uncommitted work is in scope too
```

If the user supplied a git ref in `$ARGUMENTS`, diff against that instead of `main`.
Read the **full current content** of every non-trivially changed file under `lib/` —
a diff hunk alone is not enough to reason about unwind order or lock release paths.

Load `README.md` and the files under `./documentation/` that cover the touched areas
(`DAG.md`, `background_and_async.md`, `locks_and_semaphores.md`, `retry_configuration.md`,
`interrupts.md`, `composition.md`, `core_concepts.md`, `testing.md`).

### 2. Run the Gates

Every gate produces: `PASS`, `FINDING`, or `BLOCKER`, each with concrete evidence
(`path/to/file.rb:LINE`). A gate with no changed code in its area is `N/A` — say so
explicitly rather than silently passing it.

#### G1 — Distributed Rules and Documented Claims Hold

The gem is consumed as a distributed coordinator; the docs are a contract.

- Every behavioral claim in `README.md` and `./documentation/` that touches changed code is
  still literally true. Quote the claim, then cite the code that satisfies or breaks it.
  A claim the code no longer honors is a **BLOCKER** (fix the code or fix the claim —
  the report says which, it does not do either).
- Multi-process correctness: no state that must be shared lives in a process-local ivar,
  class variable, or memoized constant where a second worker process would miss it;
  Redis keys carry the discriminators (reactor/step/run/lock identity) needed to avoid
  cross-run or cross-worker collision; TTLs exist wherever a crashed process would
  otherwise leak a key.
- Crash safety: for each new Redis write, ask what happens if the process dies
  immediately before and immediately after it. A window that strands a run with no
  sweeper/recovery path (`step_sweeper.rb`, `sweeper.rb`) is a BLOCKER.
- Serialization: anything crossing a process boundary round-trips through
  `context_serializer.rb` without silent loss (watch `false`/`nil` handling, symbol vs
  string keys, and context size limits).

#### G2 — Saga Robustness: Predictable Unwind, Compensation, Undo

The core promise of the library: a run either completes or unwinds cleanly. For every step
touched or added:

- A step producing a side effect declares rollback (`compensate`/`undo`) — and the
  reviewed code actually routes failures into it.
- **Unwind order is deterministic**: compensation runs in reverse completion order per the
  DAG, and is reproducible across runs of the same failure. Any dependence on hash order,
  thread completion order, or wall-clock ordering is a BLOCKER.
- **Compensation is idempotent and re-entrant**: running it twice (crash mid-unwind, then
  sweeper retry) leaves the same state.
- A failure *inside* compensation/undo is handled explicitly (`compensation_error.rb`,
  `undo_error.rb`) — never swallowed, never allowed to abort the remaining unwind silently.
- No orphaned steps: a step that started cannot end with neither a result nor a
  compensation record. Partial execution with no recovery path is forbidden.
- Interrupts/pause/resume remain first-class: a paused run resumes to the same DAG position
  with the same context, and unwinding a paused or resumed run compensates exactly the
  steps that actually ran — not more, not fewer.
- Async steps that fail after dispatch still reach compensation of their upstream steps.

#### G3 — Retries Do What They Claim

- Retry counting is per-step and survives process boundaries (`retry_context.rb`,
  `retry_queued_result.rb`); a retry that re-enters through a worker does not reset the
  counter or double-count it.
- `max_retries` exhaustion produces `max_retries_exhausted_failure.rb` and then flows into
  the same compensation path as any other failure.
- Backoff/delay semantics match `documentation/retry_configuration.md` exactly (units,
  first-attempt-vs-retry counting, jitter, caps).
- A retried step re-acquires whatever locks/semaphores/rate-limit tokens it needs, and
  releases those from the failed attempt first — no token or lock leak per retry.
- Retries do not re-run already-successful upstream steps and do not skip validation.
- Retry of a step with side effects either compensates the failed attempt first or is
  documented as idempotent — whichever the docs claim, the code must do.

#### G4 — Async Reactors and Steps Are Isolated

- No shared mutable state between concurrently executing steps: context writes are
  per-step and merged, not mutated in place across threads/processes.
- An async step's failure is contained — it fails its own step and the run's declared
  policy, and cannot corrupt or cross-talk into a sibling async step or another reactor
  run (`executor/async_step_dispatch.rb`, `async_waiter.rb`, `step_worker.rb`).
- Job payloads carry full identity (run id, step name, attempt) so a worker cannot act on
  the wrong run; late/duplicate job delivery is a no-op, not a second execution.
- Waiting is bounded: every wait has a timeout path (`async_wait_timeout_error.rb`) and
  `async_result_pending.rb` handling that cannot park forever.
- Adapter isolation holds: `adapters/sidekiq` and `adapters/active_job` stay
  interchangeable; no adapter-specific behavior leaks into the executor.

#### G5 — Locks Protect Resources Without Deadlocking

Covers `lock.rb`, `ordered_lock.rb`, `semaphore.rb`, `rate_limit*.rb`, `period.rb`,
`dsl/lockable.rb`, and this feature's independent step-lock work.

- Every acquire has a release on **all** paths: success, failure, compensation, undo,
  exception, pause, and process crash (TTL). Show the release path for each new acquire.
- **Deadlock freedom**: multi-lock acquisition follows one global deterministic order
  (that is what `ordered_lock.rb` is for) — no step acquires A-then-B while another can
  acquire B-then-A. Any new acquisition site must be shown to respect the order.
- No lock is held across an async dispatch or a blocking wait unless that is explicitly
  designed, documented, and TTL-bounded.
- Ownership tokens: release only releases a lock this run still owns (fencing/ownership
  check), so a TTL-expired holder cannot release a lock now held by someone else.
- Semaphore/rate-limit accounting cannot drift: crashed holders are reclaimed, and
  double-release cannot inflate available tokens.
- Behavior matches `documentation/locks_and_semaphores.md` (blocking vs non-blocking,
  timeout, what a contended run returns).

#### G6 — Validations Predictable and Run Before `run`

- Input validation executes **before** the step's `run` body — always, including on retry,
  resume-from-pause, and async re-entry paths. A path that reaches `run` with unvalidated
  input is a BLOCKER.
- Validation failures produce `input_validation_error.rb` / `validation_error.rb` as
  failures with the documented shape — never exceptions escaping the executor, never a
  silent skip.
- A validation failure produces **no side effects** and unwinds any already-completed steps
  per G2.
- dry-validation schemas stay inside the reactor/step DSL (`dsl/validation_helpers.rb`,
  `validation/`), not scattered into application code.
- Validation is deterministic: same input → same outcome, no I/O, no clock, no network
  inside a schema.
- Defaults/coercions applied by validation are visible to `run` and to serialization
  consistently (this is where `false`/`nil` bugs hide).

### 3. Verify Dynamically Where Cheap

Evidence beats reasoning. When the change touches runtime behavior, run what already
exists rather than asserting:

```bash
bundle exec rubocop
bundle exec rspec <specs covering the changed area>
```

For user-facing behavior, run it end to end against real Redis:
`docker compose run --rm demo-app bin/rails demo:<task>` (or `/demo-app-e2e-verify`).
Report command output honestly — a failing or skipped check is a finding with its output
quoted, never "should pass". If a check is not run, say which and why.

### 4. Report

Output in-session (no file writes):

```markdown
## Review — <feature> (<base>...<head>)

**Verdict**: BLOCKED | PASS WITH FINDINGS | PASS

| Gate | Result | Evidence |
|------|--------|----------|
| G1 Distributed + claims | BLOCKER | documentation/locks_and_semaphores.md:88 claims X; lib/ruby_reactor/lock.rb:142 does Y |
| G2 Saga unwind/compensation | ... | ... |
| G3 Retries | ... | ... |
| G4 Async isolation | ... | ... |
| G5 Locks / deadlock | ... | ... |
| G6 Validations | ... | ... |

### Findings

**[BLOCKER] F1 — <one-line defect>** (G5, `lib/ruby_reactor/lock.rb:142`)
Failure scenario: <concrete interleaving/inputs → wrong state or hang>
Fix: <smallest change that closes it>

### Checks Run
- `bundle exec rubocop` → <result>
- `bundle exec rspec …` → <result>
- not run: <what, why>
```

Rules for the report:

- Order findings BLOCKER → FINDING, most severe first.
- Every finding names a **concrete failure scenario** (interleaving, crash point, or input
  that produces the wrong result). A finding that cannot state one is speculation — drop it.
- No finding without a file:line. No gate row without either evidence or `N/A`.
- Verdict is `BLOCKED` if any gate is a BLOCKER, `PASS WITH FINDINGS` if only findings
  remain, `PASS` only when every in-scope gate passed **and** the checks in Step 3 ran.

### 5. Handoff

- `BLOCKED` / `PASS WITH FINDINGS`: recommend `/speckit-converge` to append the remediation
  work as traceable tasks, then `/speckit-implement`. Do not fix anything here.
- `PASS`: recommend proceeding to PR, carrying the gate table into the PR description as
  the reviewer-facing evidence.

### 6. Check for extension hooks

After producing the report, check if `.specify/extensions.yml` exists in the project root.

- If it exists, read it and look for entries under the `hooks.after_review` key
- If the YAML cannot be parsed or is invalid, skip hook checking silently and continue normally
- Filter out hooks where `enabled` is explicitly `false`. Treat hooks without an `enabled` field as enabled by default.
- For each remaining hook, do **not** attempt to interpret or evaluate hook `condition` expressions:
  - If the hook has no `condition` field, or it is null/empty, treat the hook as executable
  - If the hook defines a non-empty `condition`, skip the hook and leave condition evaluation to the HookExecutor implementation
- When constructing slash commands from hook command names, replace dots (`.`) with hyphens (`-`). For example, `speckit.git.commit` → `/speckit-git-commit`.
- For each executable hook, output the following based on its `optional` flag:
  - **Optional hook** (`optional: true`):

    ```text
    ## Extension Hooks

    **Optional Hook**: {extension}
    Command: `/{command}`
    Description: {description}

    Prompt: {prompt}
    To execute: `/{command}`
    ```

  - **Mandatory hook** (`optional: false`):

    ```text
    ## Extension Hooks

    **Automatic Hook**: {extension}
    Executing: `/{command}`
    EXECUTE_COMMAND: {command}
    ```

- If no hooks are registered or `.specify/extensions.yml` does not exist, skip silently
