# Baseline: Step Coordination Review Remediation

Recorded 2026-09-23 on `ca963444` (T001), before any 005 library change. Used to check FR-028
(no lost examples) and SC-011 (no new lint offenses) at the end.

## Full suite

`bundle exec rspec`: **1101 examples, 0 failures** (4 min 19 s).

## `spec/ruby_reactor/step_coordination/` (`--dry-run` example counts)

| File | Examples |
|---|---|
| `contention_spec.rb` | 6 |
| `declaration_spec.rb` | 15 |
| `inline_spec.rb` | 12 |
| `lock_spec.rb` | 15 |
| `observability_spec.rb` | 9 |
| `park_escalation_spec.rb` | 7 |
| `primitives_spec.rb` | 16 |
| `reentrancy_spec.rb` | 15 |
| `rollback_spec.rb` | 7 |
| `scope_spec.rb` | 2 |
| `single_site_spec.rb` | 7 |
| **Round files, folded in by US7** | |
| `review_fixes_spec.rb` | 12 |
| `review_fixes_round3_spec.rb` | 6 |
| `review_fixes_round4_spec.rb` | 3 |
| **Total** | **132** |

## Lint

`bundle exec rubocop`: 1 pre-existing offense.

- `spec/map/map_inline_execution_spec.rb:103:3` — `RSpec/MultipleMemoizedHelpers` (6/5).

## After US7 (T061)

- `ls spec/ruby_reactor/step_coordination | grep review_fixes` prints nothing: the three round
  files were folded into the behavior files and deleted. Their fixture classes (names kept) moved
  to `spec/support/reactors/step_coordination_reactors.rb`.
- `bundle exec rspec spec/ruby_reactor/step_coordination --dry-run`: **160 examples** = 132
  (baseline, round files included) + 28 new — `rollback_under_contention_spec.rb` 8 (T006),
  `ordering_parity_spec.rb` 8 (T021), `park_spec.rb` 9 (T028) + 1 (T045),
  `attribution_spec.rb` 2 (T053). No example lost.

## Finding → spec

All paths are under `spec/ruby_reactor/step_coordination/`.

| Finding | Quickstart | Spec file | Example |
|---|---|---|---|
| F1 rollback dropped under contention | R1 | `rollback_under_contention_spec.rb` | "waits for a holder that releases within the rollback wait, then runs the undo"; "reports an undo it could not re-acquire the key for, instead of dropping it silently" (+ semaphore default, raised, returned Failure, compensate, composed flattening, serialization) |
| F2 composed park releases parent holds, re-charges quotas | R2, R4 | `park_spec.rb` | "a parent rate limit across a composed park (R2) is charged once per execution"; "a parent lock across a composed park (R4) stays held through the park and is acquired exactly once"; "a park two composition levels down …" |
| F3 sync out-of-turn arrival poisons the chain | R3 | `ordering_parity_spec.rb` | "a synchronous out-of-turn arrival (R3) fails without poisoning the chain, so a later arrival still runs its body" |
| F4 attribution by `current_step` | R5 | `attribution_spec.rb` | "names the step for step-level events and nothing for reactor-level ones, across a park (R5)" (docs: `middlewares.md`, `locks_and_semaphores.md`) |
| F5 async_step park overwrites parent's root blob | P4 | `park_spec.rb` | "async_step park state (US4) keeps the unit's position and waiting marker on its record and never rewrites the parent" |
| F6 cross-level livelock | — | docs only | `documentation/locks_and_semaphores.md` "Nest keys in one order across levels" |
| F7 stale batch runs the step unordered | P1, P3 | `ordering_parity_spec.rb` | "a step whose batch expired before its retry (P1) is skipped with :ordered_lock_stale_batch …"; "gate parity (P3) stale: …" |
| F8 heartbeat survives an abnormal exit | P2 | `ordering_parity_spec.rb` | "an abnormal exit from inside the position (P2) stops the heartbeat and leaves the position for the poison pill …" |
| F9 direct call attributed to the caller | P5 | `attribution_spec.rb` | "names a directly invoked step class, not the step whose body called it (P5)" |
| F10 composed background-result wait fails the parent | R6 | `park_spec.rb` | "a background-result wait inside a composed child (R6, F10) parks the execution, keeping the child's lock, instead of failing the parent" |
| (gate parity table) | P3 | `ordering_parity_spec.rb` | "gate parity (P3)" — `go`, `wait`, `skip_chain`, `stale`, `drained` at both levels |
