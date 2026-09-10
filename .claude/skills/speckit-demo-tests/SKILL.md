---
name: "speckit-demo-tests"
description: "Generate the demo_app example reactor, rake task, and RSpec spec required by Constitution Principle VI for the current spec-kit feature, or for a context the user describes when no feature is active."
argument-hint: "Optional: what to demo/test (required if no active speckit feature is detected)"
compatibility: "Requires spec-kit project structure with .specify/ directory; writes into demo_app/"
metadata:
  author: "project"
user-invocable: true
disable-model-invocation: false
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Purpose

Constitution Principle VI ("Demo-App Proof of Feature", `.specify/memory/constitution.md`)
requires every feature to ship three artifacts together: an example reactor in
`demo_app/app/reactors/`, a task entry in `demo_app/lib/tasks/demo_reactors.rake`, and a
spec in `demo_app/spec/reactors/` written **only** with the built-in RSpec surface from
`lib/ruby_reactor/rspec.rb`. This skill produces all three in one pass.

## Step 1: Determine the context

Try to detect the current spec-kit feature first; only fall back to the user for context
if detection fails.

1. Run `.specify/scripts/bash/check-prerequisites.sh --json --paths-only` from the repo
   root and parse `FEATURE_DIR` and `BRANCH`.
2. **Speckit detected** if `FEATURE_DIR` resolves to an existing directory under `specs/`
   containing a `spec.md`. In that case:
   - Read `spec.md` (and `plan.md`/`data-model.md` if present) in `FEATURE_DIR`.
   - Extract the functional requirements (`FR-###`) and Given/When/Then acceptance
     scenarios that describe observable, runnable behavior — the ones a reactor run can
     demonstrate (happy path, a failure/compensation path, and any distinctive semantics
     like pause/resume, skip, halt, retry).
   - This extracted behavior is the context for Step 2. Do not ask the user anything
     unless the spec is ambiguous about what a runnable example should exercise.
3. **No speckit detected** (script fails, no `FEATURE_DIR`, or no `spec.md`) — the
   feature being tested must come from the user:
   - If `$ARGUMENTS` is non-empty, treat it as the context describing what to build a
     demo/test for.
   - If `$ARGUMENTS` is empty, use `AskUserQuestion` (or a plain question if that tool is
     unavailable) to ask what reactor behavior/feature the demo and spec should cover.
     Do not invent a feature — block here until the user answers.

## Step 2: Study existing conventions before writing anything

Read 1-2 existing examples so the new files match house style exactly:

- One existing reactor from `demo_app/app/reactors/` whose shape is closest to the new
  one (e.g. a failure/compensation demo, a background demo, an interrupt demo — pick by
  relevance to the context from Step 1).
- Its matching spec in `demo_app/spec/reactors/`.
- The full built-in matcher/helper surface: skim `lib/ruby_reactor/rspec.rb` and its
  `lib/ruby_reactor/rspec/*.rb` files (`helpers.rb`, `test_subject.rb`, `matchers.rb`,
  `sidekiq_helpers.rb`, `async_test_helpers.rb`). Confirm the exact set currently
  available — do not rely on a memorized list, the gem may have grown matchers since.
- The tail of `demo_app/lib/tasks/demo_reactors.rake`, in particular the `desc "All demo
  reactors"` / `task all: [...]` entry — the new task name must be appended to that
  dependency list.

## Step 3: Generate the example reactor

Create `demo_app/app/reactors/<name>_reactor.rb` (snake_case file matching the
`CamelCase` class name), where `<name>` is derived from the context (ask the user only
if the right name is genuinely ambiguous). Requirements:

- Class-based step definitions, matching Development Workflow conventions (no inline
  lambdas as the primary authoring style).
- Exercises the feature end-to-end: the happy path, and — where the feature has one — a
  failure/compensation path, typically toggled via a `fail_at:`-style input like other
  demo reactors already do.
- If the feature under test is signal-specific (Halt, Skipped, retry veto, pause/resume,
  locks, rate limits, periods), the example MUST produce that outcome observably (e.g. a
  step that calls `halt!`/`skip!`/`fail!(..., retry: false)` under a controllable input),
  not just something that happens to compile.
- Do not duplicate an existing demo reactor's purpose — if one already covers this
  behavior, extend it or say so instead of creating a near-duplicate file.

## Step 4: Register the rake task

Edit `demo_app/lib/tasks/demo_reactors.rake`:

- Add a `desc "<Reactor> — <one-line of what it demonstrates>"` /
  `task <name>: [:environment, :flush_redis] do ... end` block, following the existing
  print-the-outcome pattern (`✅ SUCCESS`, `❌ FAILED`, `⏳ BACKGROUND`, etc. — match
  whatever branch the existing tasks use for `DispatchResult`/`success?`/`failure?`).
- Run through the same scenarios the spec will assert (e.g. loop over `fail_at`
  values) so `rake demo:<name>` is a working live demonstration on its own.
- Append `:<name>` to the `task all: [...]` dependency list so it runs as part of
  `rake demo:all`.

## Step 5: Write the spec using only the built-in RSpec surface

Create `demo_app/spec/reactors/<name>_reactor_spec.rb`:

- `RSpec.describe <ReactorClass>, type: :reactor do ... end`.
- Build the subject with `test_reactor(described_class, inputs)` (see
  `lib/ruby_reactor/rspec/helpers.rb`).
- Use only the `TestSubject` API (`lib/ruby_reactor/rspec/test_subject.rb`) — e.g.
  `mock_step`, `failing_at`, `map`, `composed`, `async_step`, `async_reactor`, `resume`,
  `step_result`, `ensure_executed!`, `process_pending_jobs` — and only the matchers
  defined in `lib/ruby_reactor/rspec/matchers.rb` (`be_success`, `be_failure`,
  `have_run_step(...).after(...)`, `have_retried_step`, `have_validation_error`,
  `be_paused`, `be_paused_at`, `have_ready_interrupts`, `be_halted`, `be_skipped`,
  `be_locked`, `have_available_tokens`, `have_held_tokens`, `have_rate_limit_count`,
  `be_period_marked`, and the ordered-lock matchers) plus `drain_async_jobs` /
  `pending_async_jobs` from `sidekiq_helpers.rb` for async paths.
- **Forbidden**: any direct `RubyReactor::Executor`/`Storage`/Redis call, manual Sidekiq
  job draining, stubbing reactor internals, or any other hand-rolled scaffolding in this
  spec file.
- **If an assertion needs a matcher or helper that does not exist yet**: add it to the
  appropriate file under `lib/ruby_reactor/rspec/` in this same change (with its own
  unit coverage if the gem's own spec suite conventions call for it), then use it from
  the demo spec. Do not work around the gap with ad-hoc internals — that is what
  Principle VI explicitly forbids.
- Cover at least: the happy path (`be_success`, step ordering via `have_run_step`), and
  the failure/compensation or signal-specific path identified in Step 1.

## Step 6: Validate

Run, from `demo_app/`:

- `bundle exec rspec spec/reactors/<name>_reactor_spec.rb` — must pass.
- `bundle exec rake demo:<name>` — must run cleanly and print observable outcomes.
- `bundle exec rubocop app/reactors/<name>_reactor.rb lib/tasks/demo_reactors.rake spec/reactors/<name>_reactor_spec.rb` (from the repo root, or wherever the project's rubocop config resolves) — fix violations before finishing.

If any command fails, fix the generated files and re-run — do not report success on
files that don't pass.

## Step 7: Summarize

Report to the user:

- Files created/edited (reactor, rake task block + `all` list update, spec).
- How to run the demo (`rake demo:<name>`) and the spec.
- Whether any new matcher/helper was added to `lib/ruby_reactor/rspec/` and why.
- Confirmation that validation (Step 6) passed.
