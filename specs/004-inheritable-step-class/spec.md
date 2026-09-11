# Feature Specification: Inheritable Step Class

**Feature Branch**: `step_validations`

**Created**: 2026-09-11

**Status**: Draft

**Input**: User description: "Step complexity and refactor — the step input contracts feature (`specs/002-step-input-contracts`) added complexity to steps through workarounds that preserve the original `include RubyReactor::Step` + `def self.run(args, context)` interface. That mixin/singleton approach was chosen to keep steps stateless and easy to bolt onto existing brownfield services, but validations and upcoming features do not compose well with it: `lib/ruby_reactor/step.rb` now wraps `run` on the singleton class with hacky, magic-like interception. Revisit the decision and produce a better structure: an inheritable parent step class where the author declares inputs, writes an instance-level `run`/`undo`/`compensate`, and the parent handles validation and any future lifecycle features before invoking the body. Signals raised inside the body (`fail!`, `success!`, …) must surface as the proper result wrapper from the class-level call. No backward compatibility or deprecation handling is required — nothing is in production. If supporting both a mixin style and an inheritance style adds variance or risk, support only one."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Author a step by inheriting from the base step (Priority: P1)

A workflow author creates a step by subclassing the library's base step class. Inside the
subclass they declare the step's inputs and write the step's work as an ordinary instance
method. Inside that method they read the validated inputs and the workflow context through
accessors, return a result wrapper, or end early with a signal such as `fail!`.

Reading the base class alone explains the whole lifecycle in plain order: build an instance
with the supplied values and context, enforce the input contract, run the body, translate
any signal into a result. No method the author defines is silently intercepted, wrapped,
or replaced behind their back.

**Why this priority**: This is the whole feature. Every other story depends on the base
class existing and behaving predictably.

**Independent Test**: Define a subclass declaring one typed input and an instance-level
body; invoke it the way the reactor invokes steps, with conforming and violating values,
and observe a success result in the first case and a step-attributed validation failure in
the second — with the body never running in the failure case.

**Acceptance Scenarios**:

1. **Given** a subclass declaring a required input and a body that returns a success
   wrapper, **When** the step is invoked with conforming values, **Then** the body runs
   once, sees the validated values and the context, and the invocation returns that
   success wrapper.
2. **Given** the same subclass, **When** invoked with values that violate the contract,
   **Then** the invocation fails with a validation error naming the step and the offending
   fields, the body never runs, and the resulting failure is marked non-retryable — the
   same invalid values would fail identically on a retry, so no automatic retry path may
   attempt the body.
3. **Given** a subclass whose body calls `fail!("nop")`, **When** the step is invoked,
   **Then** the invocation returns a failure wrapper carrying `"nop"` — the signal does not
   escape as an exception to the caller.
4. **Given** a subclass whose body calls `success!`, `skip!`, or `halt!`, **When** the step
   is invoked, **Then** the invocation returns the matching success, skipped, or halt
   wrapper.
5. **Given** a subclass that declares no inputs, **When** invoked with arbitrary values,
   **Then** the body runs with those values unchanged and no validation step is performed.
6. **Given** a subclass that does not define a body, **When** invoked, **Then** the
   invocation raises a clear "must implement" error naming the subclass.

---

### User Story 2 - Reactor execution paths use the new step uniformly (Priority: P1)

A workflow author uses inheriting step classes inside reactors exactly as they use steps
today: synchronous execution, asynchronous execution through the background worker, retry,
compensation and undo on rollback, composition of reactors, map steps, and the shipped
RSpec test surface. Every one of those paths obtains the same result from the same step
with the same validation, because they all go through one entry point on the step class.

**Why this priority**: A base class that only works on the happy synchronous path breaks
the saga guarantees the library exists to provide.

**Independent Test**: Run the existing integration suites (sync, async worker, retry,
compensation, compose, map, RSpec helpers) against steps rewritten in the inheriting style
and observe identical outcomes to the pre-refactor baseline.

**Acceptance Scenarios**:

1. **Given** a reactor composed of inheriting steps, **When** run synchronously, **Then**
   dependency order, results, and failure attribution match the pre-refactor behaviour.
2. **Given** an inheriting step marked for asynchronous execution, **When** the background
   worker executes it, **Then** input validation is enforced there too and the outcome is
   recorded exactly as the synchronous path would record it.
3. **Given** a downstream step fails, **When** rollback runs, **Then** each completed
   inheriting step's undo receives that step's own result, each failed step's compensation
   receives the failure reason, and both are invoked on a fresh instance carrying the
   original values and context.
4. **Given** a step defines neither undo nor compensation, **When** rollback reaches it,
   **Then** the step is skipped and rollback continues (today's default behaviour).
5. **Given** a signal is thrown inside undo or compensation, **When** rollback reaches
   it, **Then** the signal is translated into a result wrapper just as it is for the body.
6. **Given** a spec written with the shipped test surface (`test_reactor`, `mock_step`,
   `failing_at`, matchers), **When** its subject is a reactor of inheriting steps,
   **Then** the spec passes unchanged.

---

### User Story 3 - Wrap an existing service as a step (Priority: P2)

A developer integrating the library into an existing codebase already has service objects
with their own constructors and `call` methods. They wrap one as a step by writing a small
subclass whose body instantiates the existing service with the validated inputs, calls it,
and maps its outcome to a success or failure wrapper. The existing service is not modified
and does not need to know about the library.

**Why this priority**: The brownfield use case motivated the original mixin design; the
new design must serve it at least as well, or the refactor loses a stated goal.

**Independent Test**: Take an untouched plain Ruby service class, write a subclass of the
base step of no more than a handful of lines that delegates to it, and run it through a
reactor with both a successful and a failing service outcome.

**Acceptance Scenarios**:

1. **Given** an existing service class with no library dependency, **When** a developer
   writes an adapter step subclass that delegates to it, **Then** the service runs
   unmodified and its success maps to a success wrapper carrying the service's output.
2. **Given** the same adapter, **When** the service reports failure, **Then** the step
   returns a failure wrapper carrying the service's error and triggers rollback.
3. **Given** the adapter declares inputs, **When** the reactor supplies invalid values,
   **Then** the service is never instantiated.

---

### User Story 4 - Step contracts and behaviour inherit across subclasses (Priority: P2)

A workflow author builds a family of related steps: a base step in their own codebase
declares shared inputs and helpers, and concrete steps inherit from it adding their own
inputs and body. Contracts merge parent-first, and a subclass may override the body,
undo, or compensation while still benefitting from validation.

**Why this priority**: Inheritance is the natural extension point of the new design; if it
breaks contract merging that the input-contracts feature already delivers, the refactor
regresses shipped behaviour.

**Independent Test**: Define a two-level hierarchy where the parent declares one input and
the child another; invoke the child with values missing either input and confirm both are
enforced; invoke with both and confirm the child's body runs.

**Acceptance Scenarios**:

1. **Given** a parent step declaring input A and a child declaring input B, **When** the
   child is invoked without A, **Then** validation fails on A.
2. **Given** the same hierarchy, **When** invoked with A and B, **Then** the child's body
   runs and sees both values.
3. **Given** a child overrides the body defined by its parent, **When** invoked, **Then**
   the child's body runs and validation still precedes it.

---

### User Story 5 - Documentation and demo reflect the single authoring style (Priority: P3)

A newcomer reads the README, the documentation folder, and the demo application and finds
exactly one way to write a class-based step: the inheriting style. No example, guide, or
demo reactor still uses the previous mixin style, and the changelog states plainly that the
old style was removed and how to convert.

**Why this priority**: The refactor is a breaking public-API change; a mixed documentation
set would confuse every new adopter and violates the project's documentation rule.

**Independent Test**: Search README, documentation, and the demo app for the previous
authoring form and find zero occurrences; run every `demo:` rake task and observe the same
printed outcomes as before the refactor.

**Acceptance Scenarios**:

1. **Given** the completed change, **When** the previous authoring form is searched for
   across README, documentation, demo app, and specs, **Then** no occurrences remain.
2. **Given** the demo application, **When** each `demo:` task is run against a clean Redis,
   **Then** each prints the same observable outcomes as before the refactor and its spec
   passes using only the shipped test surface.
3. **Given** the changelog, **When** a reader looks for this change, **Then** it appears
   under a breaking-change heading with a before/after conversion example.

---

### Edge Cases

- A step body raises an ordinary exception (not a signal): it propagates as it does today,
  so retry and failure attribution behave unchanged.
- A step body rescues broadly (`rescue Exception`): signals still reach the step boundary
  and produce the intended wrapper, as guaranteed today.
- The step is invoked directly (outside any reactor, e.g., in a unit test): validation and
  signal translation still apply, because there is one entry point.
- Run and rollback happen in different processes (asynchronous execution): undo and
  compensation must not rely on instance state left over from the run, only on the stored
  values, result, and context they are given.
- A step's validation failure reaches the caller by a route other than the dispatching
  process's own failure result — surfaced through a composed reactor, or reported by an
  `async_step`/`background` worker: it is non-retryable through that route too, not only
  when the validation happens to fail in the same process that will decide whether to
  retry it.
- A subclass defines its own class-level entry point: it replaces the lifecycle for that
  class (validation included) and this is documented as deliberately unsupported behaviour
  rather than silently patched around.
- Inline step bodies declared with a block inside a reactor definition keep working and
  keep access to the same signal helpers; they are unaffected by this change.
- The shipped built-in steps (compose, map, async child reactor) continue to behave
  identically to callers regardless of how they are structured internally.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The library MUST provide a single base step class that authors subclass to
  define a step; it MUST be reachable under the same public name the mixin used, so that
  `RubyReactor::Step` denotes "the way you write a step".
- **FR-002**: Subclasses MUST declare inputs and validation rules on the class using the
  same declarations the input-contracts feature introduced, with parent-first contract
  merging across subclass hierarchies preserved.
- **FR-003**: Subclasses MUST define the step's work as an instance-level body, with
  accessors for the validated inputs and the workflow context; undo and compensation are
  likewise instance-level, receiving respectively the step's stored result and the failure
  reason.
- **FR-004**: The base class MUST expose exactly one class-level entry point per lifecycle
  action (run, undo, compensate), and `call` MUST be accepted as an alias for run. Every
  execution path in the library (synchronous executor, asynchronous worker, compensation
  manager, RSpec test subject) MUST invoke steps only through those entry points.
- **FR-005**: The class-level run entry point MUST, in order: build a fresh instance from
  the supplied values and context, enforce the declared input contract (skipping
  enforcement when nothing is declared), invoke the instance body, and return the body's
  result wrapper.
- **FR-006**: Input validation failures MUST be reported as the existing structured
  validation error carrying the step name and field errors, and the body MUST NOT run.
  The resulting failure MUST report itself as non-retryable, on every path that can
  produce one from it — a direct synchronous run, an asynchronous worker, and a step
  surfaced through a composed reactor — without each of those paths having to say so
  individually.
- **FR-007**: Signals (`success!`, `skip!`, `fail!`, `halt!`) thrown anywhere inside the
  body, undo, or compensation MUST be translated at the class-level entry point into the
  matching result wrapper. Callers MUST never observe the signal mechanism.
- **FR-008**: The result-wrapper constructors (`Success`, `Failure`, `Halt`, `Skipped`)
  and the signal helpers MUST be available inside instance methods of a subclass.
- **FR-009**: Undo and compensation MUST default to "skipped" when a subclass does not
  define them, and MUST run on a fresh instance so that behaviour is identical whether or
  not the run happened in the same process.
- **FR-010**: A subclass that defines no body MUST raise a clear "must implement" error
  naming the subclass when invoked.
- **FR-011**: The base class MUST NOT intercept, wrap, prepend to, or otherwise alter
  methods the author defines; the lifecycle MUST be readable top-to-bottom as ordinary
  method calls.
- **FR-012**: The previous mixin authoring style (`include` on a plain class with
  class-level `run`) MUST be removed. No compatibility shim or deprecation path is
  provided.
- **FR-013**: Inline block-based step bodies in the reactor definition DSL MUST keep
  working unchanged, including access to the signal helpers.
- **FR-014**: All library-internal steps (compose, map, async child reactor) and every
  step in the test suite and demo application MUST be migrated to the new style, and the
  full RSpec suite and RuboCop MUST pass.
- **FR-015**: README, every affected file under the documentation folder, the demo
  application, and the changelog MUST be updated in the same change; the changelog entry
  MUST be marked as a breaking change with a conversion example.
- **FR-016**: The demo application MUST include a reactor demonstrating the inheriting
  style end-to-end, including its failure/rollback path and a brownfield service adapter,
  registered as a `demo:` rake task with a matching spec that uses only the shipped test
  surface.
- **FR-017**: A step's input-validation failure MUST be non-retryable as a single,
  centrally-enforced property of that failure — not a flag every caller that builds a
  result from it has to remember to set — so that a future execution path gets the
  guarantee automatically. This closes a gap found while implementing this feature: today
  only the asynchronous worker path sets this explicitly; the synchronous path and a
  validation failure surfaced through `compose` currently default to retryable, silently.

### Key Entities

- **Base step class**: the single inheritable parent every class-based step derives from.
  Owns the lifecycle (instantiate, validate, run, translate signals) and the default undo
  and compensation.
- **Step instance**: a short-lived object built per lifecycle action from the supplied
  values and context; the author's body, undo, and compensation execute on it. Carries no
  state across actions.
- **Input contract**: the declared inputs and rules for a step (existing entity); attached
  to the class and merged parent-first through the hierarchy.
- **Result wrapper**: success, failure, skipped, or halt outcome (existing entity);
  the only thing a class-level entry point ever returns.
- **Signal**: an early-exit helper from within a step body (existing entity); always
  translated to a result wrapper at the entry point.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A reader can explain a step's full execution order (instantiate, validate,
  run, translate signal) from the base class file alone, with no hidden method
  interception present anywhere in the step lifecycle.
- **SC-002**: 100% of class-based steps in the library, test suite, documentation, and demo
  application use the inheriting style; a search for the previous authoring form returns
  zero results.
- **SC-003**: The full existing test suite passes after migration with no reduction in
  scenario coverage, and every `demo:` rake task prints the same observable outcomes as
  before the change.
- **SC-004**: A brownfield service can be wrapped as a step in a subclass of no more than
  ten lines, without modifying the service.
- **SC-005**: Adding a future per-step lifecycle feature (for example, a pre-run hook)
  requires touching only the base class's lifecycle sequence, not any execution path or
  any author-written step.

## Assumptions

- **One authoring style.** The description allows dropping dual support if it adds
  variance or risk; it does. The mixin style is removed entirely and the inheritable class
  takes the `RubyReactor::Step` name. The brownfield case is served by a thin adapter
  subclass (User Story 3) rather than by mixing the library into an existing class.
- **No compatibility work.** Per the description, nothing runs in production; there is no
  deprecation window or shim. The changelog still records the change as breaking, per the
  project's SemVer rule.
- **Instance accessors, not method parameters.** The body reads inputs and context through
  accessors on the instance, matching the `def run` shape in the description; undo and
  compensation receive the one value the body cannot know (stored result, failure reason)
  as a parameter.
- **Existing contract semantics carry over.** Input declarations, cross-field rules,
  optional inputs, `false` handling, and parent-first merging behave exactly as delivered
  by the input-contracts feature; this change moves where enforcement lives, not what it
  does.
- **Signal mechanism unchanged.** Signals keep their existing early-exit semantics
  (including surviving broad rescues); only the place where they are caught moves to the
  step's single entry point.
- **Inline block steps are out of scope** beyond confirming they still work; they remain
  the lightweight alternative to a class.
- **Naming of the step-level `argument` DSL** and other input-contracts follow-ups are not
  part of this change.
