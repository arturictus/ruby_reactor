# Phase 0 Research: Reactor Signal Semantics

All unknowns from Technical Context are resolved below. Each decision was
checked against the current code; file:line references are the sites the
decision touches.

---

## R1 — Class hierarchy for `Halt` and `Skipped`

**Decision**: Both remain subclasses of `Success`.

- `Halt < Success` — today's `Skipped` class renamed verbatim (same
  `reason` / `period_key` / `step_name` readers), predicate `halted?`.
- `Skipped < Success` — new, wraps a value like `Success`, optional `reason`,
  predicate `skipped?`.
- `Success` and `Failure` both answer `halted?` → `false` and `skipped?` →
  `false`.
- Every `case` dispatch orders **Halt → Skipped → Success**.

**Rationale**: The executor has several `case result` sites and multiple
`is_a?(RubyReactor::Success)` fallbacks
(`retry_manager.rb:97`, `executor.rb:557`, `result_handler.rb:20`,
`map/result_enumerator.rb:88`). If either signal stopped being a `Success`, any
site not explicitly updated would fall through to
`result_handler.rb#handle_unknown_result` — which wraps the object as a step's
*value*, silently corrupting the run. Subclassing keeps unvisited sites correct
by default and reduces the change to the sites that genuinely need new
behaviour.

**Alternatives considered**:
- *Separate `Signal` base class for all four outcomes.* Cleanest taxonomy,
  largest diff, and every missed site becomes a silent corruption. Rejected on
  Principle V (simplicity) and the risk above.
- *`Halt` not a `Success` (it is not a success, semantically).* Truthful naming,
  but forces new branches into retry, map, telemetry, and serializer paths for
  behaviour that is already correct today. Rejected — the rename must not change
  behaviour (SC-001).

**Loud-failure aid**: the halt class drops `skipped?` entirely. Any site that
still asks a halt `skipped?` raises `NoMethodError` in tests rather than
returning a plausible `false`.

---

## R2 — Non-local exit for `success!` / `fail!` / `skip!` / `halt!`

**Decision**: `throw`/`catch` with a module-private tag
(`RubyReactor::StepSignals::TAG`). Helpers `throw(TAG, <signal>)`; the executor
wraps each step-body invocation in `catch(TAG) { ... }`.

Wrap sites:
- `executor/step_executor.rb:292-297` — `run_block.call` and `impl.run`
- `executor/compensation_manager.rb:60-66` — compensate block / `impl.compensate`
- `executor/compensation_manager.rb:100-106` — undo block / `impl.undo`

**Rationale**: verified in Ruby 3.4 that a `throw` caught by an enclosing
`catch` is **not** intercepted by `rescue Exception`, while `ensure` blocks
still run:

```ruby
catch(:sig) do
  begin
    throw(:sig, :thrown)
  rescue Exception => e   # never reached
  ensure                  # runs
  end
end # => :thrown
```

This is exactly FR-021: `step_executor.rb:143`'s `rescue StandardError => e`
converts any raised error into a `Failure`, so an exception-based helper would
be swallowed and reported as an error rather than the author's intended outcome.

**Alternatives considered**:
- *Custom exception subclass rescued before `StandardError`.* Needs a matching
  `rescue` at every invocation site plus discipline forever after; a user's
  `rescue => e` inside their own step body would still swallow it. Rejected.
- *`return` from the block via `next`.* Does not work from nested method calls
  (FR-017), which is the whole point of the helpers. Rejected.

---

## R3 — Where the helpers are defined

**Decision**: one new file `lib/ruby_reactor/step_signals.rb` defining
`RubyReactor::StepSignals` with the tag and the four helpers; included into both
authoring surfaces:

- `RubyReactor::Step::ClassMethods` (`step.rb:9`) — class-based steps, where
  `self` inside `.run` is the step class.
- `RubyReactor::Dsl::TemplateHelpers` (`dsl/template_helpers.rb`) — inline
  blocks, where `self` is the reactor class because `run_block.call` is a plain
  `.call` and the block closes over its definition scope.

**Rationale**: those two modules are already where `Success()`/`Failure()`/
`Skipped()` live for the two styles, so the helpers reach both surfaces with
zero new plumbing and identical behaviour (FR-018).

**Alternatives considered**: `instance_exec`-ing run blocks against a fresh
context object so helpers are instance methods. Rejected — it would change `self`
inside every existing inline block, breaking user code that calls reactor-level
methods.

---

## R4 — `retry:` on `Failure` and `fail!`

**Decision**: `Failure#initialize` gains `**opts`; `retryable` is taken from
`opts[:retry]` when present, otherwise from the existing `retryable:` keyword,
otherwise from the error's own `retryable?`, otherwise `true`. `fail!` forwards
both spellings unchanged.

Verified shape:

```ruby
def initialize(error, retryable: nil, **opts)
  retryable = opts[:retry] if opts.key?(:retry)   # new spelling wins
  ...
end
```

**Rationale**: `retryable` is serialized into stored failures
(`context_serializer.rb:45`, read back at `:120`) and is part of the current
public API (`spec/examples/locking_reactors.rb:247`). Renaming it would break
in-flight durable state on upgrade. `**opts` sidesteps the question of whether
`retry:` is usable as a formal parameter name (it parses, but the body cannot
reference it as a local), and works identically on Ruby 3.0.

**Retry flag is a veto, confirmed in code**: `retry_manager.rb:112` gates on
`can_retry_step?(step_config) && result.retryable?`, and `can_retry_step?`
(`:23`) requires `step_config.retryable?` plus attempt budget. So a
`retry: true` failure on a non-retryable step still runs once — FR-028 is
already true and only needs a test.

**Alternatives considered**: rename `retryable:` → `retry:` with a shim.
Rejected — breaks stored state for no user-visible gain.

---

## R5 — Only `Failure` enters the retry machinery

**Decision**: no behaviour change; add branches only for clarity plus tests.

`retry_manager.rb#handle_retry_result` matches `when RubyReactor::Success` →
clears retry state and returns. Because `Halt` and `Skipped` are `Success`
subclasses (R1), they already bypass retry, backoff, and re-enqueue, and already
clear retry state — satisfying FR-029 and FR-031 as written. Tasks add explicit
`when` arms (readability) and the covering tests (SC-008, SC-010).

**Rationale**: cheapest path to a requirement that is already met; the tests are
the actual deliverable.

---

## R6 — Migration guard for the reused `Skipped` name

**Decision**: `Skipped.new` takes a positional value; a call whose only
argument is a `reason:` keyword raises `ArgumentError`:

```
RubyReactor::Skipped now marks a single step as skipped and continues.
The clean halt you want is RubyReactor.Halt(reason: ...) / halt!(reason: ...).
```

Guard lives in both `Skipped#initialize` and the module builder
`RubyReactor.Skipped` (`ruby_reactor.rb:329`).

**Rationale**: an alias cannot help when the *name* is reused with inverted
semantics. Without the guard, `RubyReactor.Skipped(reason: "opted out")` would
be read as a skip carrying the hash `{reason: "opted out"}` as its value — the
reactor would continue instead of halting, silently violating the author's
intent (FR-006). One guard beats a deprecation cycle (Principle V).

**Accepted cost**: `skip!(reason: "x")` as a *value* is unreachable. Documented;
authors pass `skip!({reason: "x"})` if they truly want that hash.

**Alternatives considered**: keep `Skipped` meaning halt and name the new signal
something else (`Noop`, `Passed`). Rejected — the requester explicitly wants the
name `Skipped` to mean per-step skip.

---

## R7 — Status vocabulary and durable state

**Decision**:
- New run status `:halted`. A run never ends `:skipped` any more.
- Status whitelists accept `"halted"` **and** legacy `"skipped"`, and reads map
  `"skipped"` → halted: `storage/redis_adapter.rb:235`, `web/api.rb:150`,
  `map/sweeper.rb:95` (terminal-status list).
- `executor.rb#update_context_status` (`:505`) gains a `when RubyReactor::Halt`
  arm before `Skipped`/`Success`; a run containing skipped steps still ends
  `:completed`.
- `executor.rb#mark_period_on_success` (`:374`) excludes `Halt` (it excludes
  `Skipped` today) and **includes** runs with skipped steps — a completed run
  claims its period bucket.

**Rationale**: contexts stored by the previous version are in Redis during
upgrade; refusing their status would strand runs mid-flight. Translating on read
is two lines and costs nothing afterwards.

---

## R8 — Execution trace shape

**Decision**:

| Event | Trace entry |
|---|---|
| Clean halt | `{ type: :halt, step:, reason:, timestamp: }` (was `:skipped`) |
| Step skipped | `{ type: :skipped, step:, reason:, timestamp: }` (new meaning) |
| Compensation | existing `:compensate` entry gains `skipped: true/false` |
| Undo | existing `:undo` entry gains `skipped: true/false` |

The trace is serialized (`context.rb:118`) and is how async runs reconstruct
their outcome (`rspec/test_subject.rb:282-287`), so both entries survive the
worker boundary. Trace entries carry the *reason*, never the skipped value —
values already live in `intermediate_results`.

**Rationale**: keeps the async reconstruction path working (it greps the trace
for the terminal event) and gives the dashboard and OTel a per-step source of
truth without a second store.

---

## R9 — `compensate` / `undo` defaulting to `Skipped`

**Decision**: the four "nothing defined" defaults return `RubyReactor.Skipped()`
instead of `RubyReactor.Success()`: `step.rb:29`, `step.rb:33`,
`compensation_manager.rb:66`, `compensation_manager.rb:108`.

No control-flow change is needed: `compensation_manager.rb:25`'s
`when RubyReactor::Success` still matches (`Skipped < Success`), so rollback
continues exactly as before (FR-023).

`open_telemetry.rb:603-605` and `:624-626` already emit
`compensation.status = "skipped"` / `undo.status = "skipped"` when the result is
skipped — today unreachable, after this change accurate. No edit needed there.

**Rationale**: the smallest possible change that makes the trace honest
(FR-022/FR-024), riding on machinery that already exists.

---

## R10 — Map / element execution

**Decision**: skipped elements flow as values with no change —
`map/result_enumerator.rb:88` greps `RubyReactor::Success`, which matches
`Skipped`. Element-level `Halt` needs an explicit branch in the collector path
so it propagates as a run halt instead of being collected as a value.

**Rationale**: matches the spec's edge cases; the `Skipped` half is free, the
`Halt` half is one branch plus a test.

---

## R11 — Test surface

**Decision**:
- New matcher `be_halted` with the existing `.because(reason)` / `.at_step(name)`
  chains — a copy of today's `be_skipped` (`rspec/matchers.rb:267-307`) against
  `halted?`.
- `be_skipped` is repurposed: asserts a **step** was skipped, chainable with
  `.at_step(name)`, reading the result or the execution trace.
- `rspec/test_subject.rb:253` maps status `"halted"` (and legacy `"skipped"`) to
  a reconstructed `Halt`; `skipped_result` is renamed `halted_result` and greps
  the trace for `type: :halt`.

**Rationale**: every existing clean-halt test migrates by renaming the matcher,
which is exactly the visibility SC-001 needs.

---

## R12 — Dashboard (`gui/`) state rendering

**Decision**: the React dashboard in `gui/` gets four edits plus an asset
rebuild. The load-bearing one is how a step's state is derived.

### The trap: skipped steps look completed

`gui/src/components/DagVisualizer.tsx:313-315` derives a step's node state from
the presence of a stored value:

```ts
if (currentResults && currentResults[key] !== undefined) {
  statusMap[fullId] = 'completed';
}
```

A skipped step **does** store a value (FR-008), so without a change every
skipped step renders as a green completed node — the new signal would be
invisible in the one place operators look. Fix: consult the execution trace for
`{ type: 'skipped', step: key }` **after** the value check and override to
`'skipped'`; likewise `{ type: 'halt', step: key }` → `'halted'` for the
halting node. The trace is already passed into the component as `steps`.

**Alternatives considered**: have the API return a per-step status map. Cleaner
component, but a new API surface plus serializer work for something the trace
already carries. Rejected on Principle V.

### The second trap: rollback list calls everything "executed"

`gui/src/components/StepInspector.tsx:180-186` maps every `:compensate` /
`:undo` trace entry to `status: 'executed'`. Once the defaults return `Skipped`
(R9), steps that never had compensation written will appear in the rollback
panel as *executed compensation* — actively misleading, and the exact opposite
of what FR-024 asks for. Fix: read the new `skipped:` flag on the entry and
render a third state ("not implemented").

### Run-status vocabulary

| Site | Today | After |
|---|---|---|
| `gui/src/components/StatusBadge.tsx:8,17` | `skipped` badge (sky, SkipForward) | `halted` badge; keep a `skipped` entry for per-step use |
| `gui/src/components/ReactorDetail.tsx:80` | `status === 'skipped'` → sky text | `'halted'` |
| `gui/src/components/LiveView.tsx:62` | filter `<option value="skipped">` | `halted`, labelled "Halted" |
| `gui/src/components/ReactorClassInstances.tsx:69` | same filter | same change |
| `gui/src/lib/reactors.ts:32` | counts `skipped` in the success bucket | counts `halted` (and legacy `skipped`) there |

Legacy rows keep rendering because the API translates the stored `"skipped"`
status to halted (R7) before it reaches the browser, so the GUI needs the
legacy string only in the aggregate helper's defensive branch.

### Asset rebuild

`Rakefile:8-22` (`rake build:ui`) runs `npm run build` in `gui/` and copies
`gui/dist/.` into `lib/ruby_reactor/web/public/`, which is committed to the
repo. The task must run and its output be committed, or an installed gem serves
the old bundle (FR-040).

**Test surface**: `gui` uses vitest with existing component tests
(`gui/src/components/__tests__/`, `gui/src/lib/__tests__/`). New cases go
alongside: a skipped-step DAG fixture, a halted-run fixture, and a rollback
panel fixture with one implemented and one unimplemented compensation.
