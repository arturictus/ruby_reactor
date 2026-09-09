---
name: "demo-app-e2e-verify"
description: "Boot demo_app via docker-compose, run demo_reactors.rake, auto-derive acceptance criteria from the reactor/rake source, and cross-check actual behavior against both the RubyReactor API and dashboard at localhost:[port]/ruby_reactor. Writes findings + a fix plan to a tmp report."
argument-hint: "Optional: specific rake task(s)/reactor(s) to focus on (default: all)"
compatibility: "Requires docker compose and the demo_app/lib/tasks/demo_reactors.rake tasks"
metadata:
  author: "project"
user-invocable: true
disable-model-invocation: false
---

## User Input

```text
$ARGUMENTS
```

If non-empty, scope the run to the named rake task(s)/reactor(s) instead of `demo:all`.
Otherwise run everything.

## Purpose

End-to-end confidence check for `demo_app`: does what the rake demos claim to do actually
show up correctly in the RubyReactor API and dashboard? This is not a spec-kit workflow —
it derives its own expectations from the current code rather than from `specs/`.

## Step 1: Bring the stack up

1. `docker compose ps` to see what's already running; avoid tearing down containers the
   user didn't ask to stop.
2. `docker compose up -d demo-redis demo-sidekiq demo-app` (skip `redis-test`/`teley`
   unless already running — they're not needed for this check). If it fails with a
   container name conflict (`container_name` is static, and this repo runs from multiple
   git worktrees sharing one docker daemon), check `docker ps -a --filter name=ruby_reactor`
   — if the conflicting containers are `Exited` (not running), it's safe to `docker rm`
   them and retry; never `rm` a container that's currently `Up` without asking, it may
   belong to another worktree's active session.
3. Poll `docker compose ps` / container healthchecks until `demo-redis` and `demo-sidekiq`
   report healthy, and until the Rails server inside `demo-app` responds. Use a
   short polling loop (not a fixed sleep) against `http://localhost:3789/ruby_reactor` —
   treat a non-timeout HTTP response (even a 404/500) as "server is up", empty/refused as
   "still booting". Cap the wait (e.g. ~90s) and report clearly if it never comes up.
4. Read the exposed host port for `demo-app` from `docker-compose.yml` at runtime rather
   than assuming `3789` — the file may have changed.

## Step 2: Auto-learn the expected behavior (before running anything)

For each rake task in scope, build an acceptance-criteria list by reading the source, not
by assuming:

1. Read `demo_app/lib/tasks/demo_reactors.rake` — for each in-scope task, note: which
   reactor(s) it calls, what inputs/scenarios it loops over (e.g. `fail_at` values), and
   what output markers it prints for success/failure/background/pause (`✅`, `❌`, `⏳`,
   etc.).
2. Read the corresponding reactor class(es) in `demo_app/app/reactors/`. For each step,
   note: what triggers it to succeed/fail/halt/skip/retry-veto, what its rollback (undo)
   does if it has side effects, and any locks/rate-limits/periods/interrupts it declares.
3. From that, derive one acceptance criterion per scenario, e.g.:
   - "`fail_at: nil` → task prints ✅, reactor status is `success`, `execution_trace`
     contains every step in dependency order, `error` is nil."
   - "`fail_at: :capture_payment` → task prints ❌, reactor status is `failed`/`halted`,
     steps after `capture_payment` never ran, steps before it with side effects appear in
     `undo_stack` (or show a compensation trace), `error` mentions the trigger."
   - For background/async reactors: expect a `DispatchResult`/`⏳` print, then (after
     `drain`/wait) a terminal status reachable via the API.
   - For interrupt/pause reactors: expect `be_paused`-equivalent status and
     `ready_interrupts`/`current_step` matching the interrupt step.
4. Keep this list in memory (or a scratch note) — it is what Step 4 checks results against.
   If a reactor's behavior can't be inferred confidently from its source, say so explicitly
   rather than guessing an expectation.

## Step 3: Run the demos

1. Execute the in-scope rake task(s) inside the running container:
   `docker compose exec -T demo-app bin/rails demo:<task>` (or `demo:all` by default).
2. Capture full stdout. Extract, per scenario run: reactor class, inputs used (especially
   any `fail_at`/scenario discriminator), the printed outcome marker, and any
   `execution_id`/`context_id`/`order_id` printed — these are the join key to the API in
   Step 4. If a task doesn't print an id, look up the id via the API list endpoint
   (Step 4.1) by class name + recency instead of skipping verification.
3. For async/background scenarios, allow Sidekiq (already running as `demo-sidekiq`) time
   to process, then re-check rather than asserting immediately. `demo:all` runs heavy
   background tasks back-to-back (`map`'s ~30 jobs, `ar`'s ~100 product jobs, the lock/
   semaphore/coordination holds) — an async/await step later in the chain (e.g.
   `async_step_demo`, `async_reactor_demo`) can hit `async_wait_timeout` purely from
   Sidekiq queue backlog, not a real bug. Before reporting an async timeout as a finding,
   re-run that one task in isolation (`bin/rails demo:<task>`) once the queue has drained
   — if it passes clean alone, it's a demo-ordering/concurrency artifact (note it under
   Suggestions, e.g. "raise Sidekiq concurrency" or "reorder demo:all"), not a code bug.

### Splitting the run across agents (avoid context overload)

For `demo:all` (or any multi-task scope), don't run Steps 2-5 for every task in one
context — the full run is ~19 tasks / 80+ scenarios and will blow past a useful context
budget long before the report is written. Instead:

1. Do Step 1 (stack up) and a first pass of Step 2 yourself: skim
   `demo_reactors.rake` and `git status`/`git log` for the reactors involved to identify
   which ones are new/actively-changing right now (untracked files, recent commits touching
   `app/reactors/`) — those get priority full-depth verification.
2. Group the remaining tasks (e.g. by rake task, or a few related tasks per group) and
   fan them out to parallel background agents, each self-contained: give it the exact
   `docker compose exec` command, the port, which reactors/tasks it owns, the acceptance-
   criteria method from Step 2, and the Step 4/5 validation + fix instructions verbatim.
   Tell each agent explicitly which scenarios warrant full API depth-check (`GET .../<id>`
   against every field) versus which can be validated via stdout markers plus a 1-2
   scenario spot-check — exhaustively hitting the API for every scenario in a large group
   is what overloads context, not running the scenarios themselves.
3. Have each agent write its own findings; collect and merge into the single report in
   Step 6 yourself (or have one agent own the merge) rather than re-deriving everything in
   your own context.

## Step 4: Validate against both data sources

For every scenario captured in Step 3, check it against **both**:

**(a) The API** (`http://localhost:<port>/ruby_reactor/api/reactors`):
- `GET /ruby_reactor/api/reactors` — list; confirm the run's reactor/context appears.
  Known limitation to watch for: the storage adapter's `scan_reactors` caps at `count: 50`
  via Redis `SCAN` with no chronological ordering — on a run with 50+ total executions
  (e.g. `demo:all`), some earlier ones can be genuinely absent from the list endpoint even
  though `GET .../<id>` finds them directly by id. Don't assume "missing from the list" ==
  "reactor didn't run" — try the direct id lookup before concluding it's a bug, but if it
  IS a real gap, it's a known gem-level finding (no `limit`/`cursor` param threaded through
  `lib/ruby_reactor/web/api.rb` → `lib/ruby_reactor/storage/redis_adapter.rb` `scan_reactors`).
- `GET /ruby_reactor/api/reactors/<id>` — confirm `status`, `current_step`,
  `execution_trace` (`steps`), `undo_stack`, `retry_count`/`step_attempts`, `error`,
  `coordination`, and `structure` match the acceptance criterion from Step 2. Compare
  step ordering and dependency edges against `structure`/`depends_on`, not just final
  status.
- **Cross-check the rake task's own printer branches against every outcome type the
  reactor can actually produce**, not just its final API status. A common bug class here:
  a `run_*` helper in the rake task branches on `DispatchResult` / `success?` / `failure?`
  but is missing a `halted?` (or `skipped?`) branch, so a reactor that legitimately halts
  (e.g. a dedup/period-lock halt, which is `Halt < Success`) falls through to the
  `success?` branch and prints a misleading `✅ SUCCESS: nil` while the API correctly shows
  `status: "halted"`. Read every `run_*`/`report_demo_result` helper the in-scope tasks use
  and check its branch list covers everything the reactor's `signals`/return values allow.

**(b) The dashboard** (`http://localhost:<port>/ruby_reactor`):
- Confirm the root path serves the SPA (HTTP 200, HTML with its mount point) — a broken
  dashboard build is itself a finding.
- Where practical, fetch the same reactor's dashboard state the UI would render (it is
  backed by the same API, so this mainly confirms the mount + asset pipeline are healthy
  end-to-end, not just the API module in isolation). Note any divergence between what the
  rake stdout claimed and what the API/dashboard actually recorded — that divergence is
  the primary class of bug this skill hunts for.

Also check for **coverage gaps**: any reactor in `demo_app/app/reactors/` with no
corresponding rake task (nothing exercises it), and any acceptance criterion from Step 2
that neither data source could confirm (e.g. no id was ever discoverable).

## Step 5: For every bug found, propose a fix and a regression test

A finding is not done at "here's what's wrong" — for each confirmed bug/error:

1. **Root-cause it**: trace the mismatch to the actual code (a step's outcome, the API
   serializer, storage, the dashboard build) rather than stopping at "API returned X,
   expected Y". Name the file(s)/line(s) responsible.
2. **Propose a concrete fix**: a diff-level description (or, if the fix is small and
   unambiguous, apply it — see below) of what changes and why, referencing the gem's
   principles (`.specify/memory/constitution.md`) where relevant (e.g. don't silently
   widen behavior beyond what the demo actually needs).
3. **Propose the regression test** that would have caught it, and place it correctly:
   - **Bug in gem behavior** (executor, signals, storage, adapters, DSL, the `Web::API`
     serializer, etc.) → a unit/integration spec under `spec/` (mirror the existing
     layout, e.g. `spec/ruby_reactor/web/` for API bugs, `spec/ruby_reactor/executor/`
     for execution-order bugs) using the gem's normal spec helpers — **not** the
     `RubyReactor::RSpec` demo helpers, those are for `demo_app`.
   - **Bug only reachable through the demo reactor's own definition, the rake task, or
     dashboard integration** → a spec under `demo_app/spec/reactors/`, `type: :reactor`,
     using only the built-in surface from `lib/ruby_reactor/rspec.rb` (see
     `speckit-demo-tests` skill for the exact matcher/helper list and the "no hand-rolled
     scaffolding" rule — apply the same constraint here).
   - If the bug spans both (a gem defect that happens to surface via a demo reactor),
     propose **both**: a gem-level spec pinning the underlying behavior, and a demo spec
     confirming the demo reactor now reports it correctly.
4. Do not apply gem-behavior fixes automatically without asking — surface them in the
   report. You MAY apply a fix that is confined to `demo_app/` (a demo reactor, the rake
   task, or a demo spec) directly if it's unambiguous, then note that it was applied and
   re-verify it in this same run. Never silently skip proposing the regression test even
   when you don't apply the fix itself.

## Step 6: Write the report

Write findings to `demo_app/tmp/demo_verification/<UTC timestamp>-report.md` (create the
directory if needed; it's already gitignored via `demo_app/.gitignore`). Structure:

```markdown
# Demo App E2E Verification — <timestamp>

## Scope
<tasks/reactors run, port used, docker services status>

## Acceptance criteria checked
<the Step 2 list, one line per scenario>

## Results
| Reactor | Scenario | Rake output | API result | Dashboard | Verdict |
|---|---|---|---|---|---|
...

## Errors found
<concrete mismatches: expected vs actual, with the reactor/context id and relevant
API JSON excerpt or rake stdout excerpt, plus root cause (file/line)>

## Suggestions / improvements
<non-broken but worth-fixing observations: missing rake coverage, confusing output,
missing undo, etc.>

## Fix plan
<per error: ordered, concrete steps to resolve it — file(s) to touch, what changes,
whether it was already applied — followed by the regression test proposed for it
(file path + what it asserts) and whether it was added/passing>
```

Keep the table terse; put raw JSON/log excerpts in fenced code blocks under "Errors
found", not inline in the table.

## Step 7: Summarize to the user

Report: report file path, pass/fail counts, and the top few errors (if any) inline —
each with its proposed fix and regression test location — so the user doesn't have to
open the file to know whether anything broke or what to do about it. If everything
passed, say so plainly — don't manufacture findings. Do not tear down the docker services
unless the user asks; mention they're still running.
