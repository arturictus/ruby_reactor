# Phase 1 Data Model: Inheritable Step Class

This feature has no persisted schema or database entities — it reshapes an in-memory
authoring/execution abstraction. "Entities" here are Ruby-level concepts, matching the
Key Entities section of spec.md, made concrete for implementation.

## `RubyReactor::Step` (the base class)

The single inheritable parent every class-based step derives from. Replaces the current
`module RubyReactor::Step` (mixin) — same constant name, different kind of object (a
`Class`, not a `Module`), per spec FR-001 and FR-012.

**Class-level surface** (the lifecycle, callable by every execution path per D1):

| Method | Signature | Behavior |
|---|---|---|
| `self.run` | `(arguments, context)` | Enforce input contract if declared (skip if `declares_inputs?` is false; a violation *raises* `InputValidationError` with `step_name` set, outside any catch) → `new(validated, context)` (D2/D3) → `catch(StepSignals::TAG) { instance.run }` → return the result wrapper or the caught signal's wrapper |
| `self.call` | `(arguments, context)` | Alias of `self.run` (D1) |
| `self.undo` | `(result, arguments, context)` | `new(arguments, context, result: result)` — fresh instance (D2/D3) → `catch(StepSignals::TAG) { instance.undo }` |
| `self.compensate` | `(reason, arguments, context)` | `new(arguments, context, reason: reason)` — fresh instance (D2/D3) → `catch(StepSignals::TAG) { instance.compensate }` |

The class-level entry points own the `catch` — that is what makes `StepWorker` (which has
no catch of its own today, see research.md D4) behave identically to the executor for
class steps without touching the worker.

**Class-level DSL surface** (unchanged from today, ported verbatim from the current
`ClassMethods` module per D5/D6 — ***not*** part of this feature's design decisions, just
carried forward):

- `input(...)`, `validate_inputs(...)` — delegate to `own_input_contract` (unchanged
  `InputContract`, `lib/ruby_reactor/step/input_contract.rb`, untouched by this feature).
- `input_contract`, `declared_inputs`, `required_input_names`, `declares_inputs?` —
  unchanged, including the parent-first `merge` on `inherited` (spec FR-002, User Story 4).
- `inherited(subclass)` — **deleted.** Today it exists solely to re-prepend
  `InputEnforcement` onto each subclass's singleton class; contract memoization
  (`@input_contract`, `@own_input_contract`) is already per-class instance variables and
  needs no reset. With the prepend gone, the hook has nothing left to do.

**Result-wrapper / signal helpers available inside instance methods** (spec FR-008):
`Success`, `Failure`, `Halt`, `Skipped` and the `StepSignals` throw helpers (`success!`,
`skip!`, `fail!`, `halt!`) must be callable as bare instance methods inside `run`/`undo`/
`compensate` bodies — the base class includes `RubyReactor::StepSignals` at the instance
level (not only, as today, at the class/singleton level) and defines the same four
`Success`/`Failure`/`Halt`/`Skipped` wrapper methods as instance methods, delegating to
the module-level `RubyReactor.Success` etc.

## `Step` instance (short-lived, per lifecycle action)

Built fresh for every `run`/`undo`/`compensate` call (D2) — never reused, never crosses a
process boundary as an object (only its inputs do, via the normal `arguments`/`context`/
`result`/`reason` that already flow through Redis-backed context serialization
unaffected by this feature).

Constructor: `initialize(inputs, context, result: nil, reason: nil)` (research.md D3).

| Reader | Holds | Set by | Read by |
|---|---|---|---|
| `inputs` | the argument hash with the contract's defaults applied (raw if no contract), identical in every action | `self.run` after enforcement; `self.undo`/`self.compensate` apply defaults only, never enforce | `run`, `undo`, `compensate` |
| `context` | the workflow `RubyReactor::Context` | constructor | `run`, `undo`, `compensate` |
| `result` | the step's own stored result value | `self.undo`'s `result` parameter; nil otherwise | `undo` |
| `reason` | the failure that triggered rollback | `self.compensate`'s `reason` parameter; nil otherwise | `compensate` |

All four are plain `attr_reader`s set once in the constructor. No other mutable state. An
instance built for `run` is discarded after `self.run` returns; `undo`/`compensate` never
read anything a prior `run` instance touched (this is the D2 guarantee that closes the
Complexity Tracking risk in plan.md).

Namespace: `RubyReactor::Step` is now a class, so the four constants under it
(`Step::InputContract`, `Step::ComposeStep`, `Step::MapStep`, `Step::AsyncReactorStep`)
live inside a class rather than a module — every file that opens the namespace must say
`class Step` (research.md D9).

## `InputContract` (existing, unchanged)

No structural change. Still owns `declarations`, `cross_field_validators`, `#enforce!`,
`#merge` (parent-first), `#empty?`/`declares_inputs?`. This feature relocates *who calls*
`#enforce!` (from a `singleton_class.prepend`-installed `InputEnforcement#run` to
`self.run`'s own body) without touching the contract's own behavior — every acceptance
scenario in the prior feature (002-step-input-contracts) that exercises `InputContract`
directly is unaffected.

## Result wrapper / Signal (existing, mostly unchanged)

`Success`, `Failure`, `Halt`, `Skipped` (module-level constructors in `RubyReactor`) and
`StepSignals::TAG` throw/catch mechanism are unchanged in shape and semantics — this
feature only relocates *where* the `catch(StepSignals::TAG)` for a class-based step's own
body lives (D4), not what a signal means or how it is thrown.

One property is fixed, not just relocated: a `Failure` built from a validation error is
always non-retryable (`retryable?` returns `false`), regardless of which execution path
produced it. This is enforced once, on `Error::InputValidationError#retryable?` itself
(research.md D10) — `RubyReactor::Failure` already asks the wrapped error object, so no
call site (synchronous executor, async worker, compose) has to remember to say so.

## Relationships

```text
RubyReactor::Step (class)
  │  subclassed by
  ▼
Concrete step class (e.g. MyStep, ComposeStep, MapStep, AsyncReactorStep)
  │  declares (class-level DSL)          │  invoked by (class-level entry points)
  ▼                                      ▼
InputContract (declarations, merge)     Executor::StepExecutor / CompensationManager /
                                         RSpec::TestSubject (unchanged call sites)
  │  enforced by self.run, producing
  ▼
validated argument hash ──────────────► Step instance (per-action, D2)
                                              │  run/undo/compensate body executes,
                                              │  may throw a Signal
                                              ▼
                                         StepSignals::TAG catch (D4, at self.run/undo/compensate)
                                              │
                                              ▼
                                         Result wrapper (Success/Failure/Halt/Skipped)
```
