# Feature Specification: Step-Scoped Retry Declarations

**Feature Branch**: `retry_confs_in_steps`

**Created**: 2026-09-25

**Status**: Draft

**Input**: User description: "As we did previously with `locks` we have to continue moving
configurations from the main reactor to the steps. Currently:

```ruby
class PaymentReactor < RubyReactor::Reactor
  background all: true

  step :charge_card, ChargeCard do
    retries max_attempts: 3, backoff: :exponential, base_delay: 5.seconds
  end
end
```

But we are designing the DSL so that steps are encapsulated units of work that know the best way
to be executed. The preferred way:

```ruby
class ChargeCard < RubyReactor::Step
  with_lock(...)                          # already implemented
  input :email, :string, format?: EMAIL_REGEX
  retries max_attempts: 3                 # AND!!

  def run
    logic
  end
end
```

As always, inline reactor steps and reactor declarations are supported and maintained. This is
valid:

```ruby
class PaymentReactor < RubyReactor::Reactor
  background all: true

  step :charge_card do
    retries max_attempts: 3, backoff: :exponential, base_delay: 5.seconds
    run { PaymentService.charge(card_token, amount) }
  end
end
```

We have to emulate the logic and behaviour we implemented for locks and inputs."

Follow-up from the user: "And we should remove altogether the retry defaults (`retry_defaults`
on the reactor). Those are a bad practice and make retries unpredictable."

## Clarifications

### Session 2026-09-25

- Q: Should a direct call to a step class (outside any reactor) honor the class's retry
  policy? → A: No. A direct call runs once. Only the reactor coordinates retries.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Remove reactor-wide retry defaults first (Priority: P1, delivered first)

An author reading a reactor must be able to tell how each step is retried by looking at that
step alone: its class or its step block. Reactor-wide retry defaults break this, because a
line at the top of a reactor silently changes how every step without its own policy behaves.
The same step class can be retried three times in one reactor and never in another, and
moving a line up or down in the reactor changes which steps it applies to.

Reactor-wide retry defaults are removed. A step that declares no policy runs once. Reactors
that still call the removed declaration fail to load with a message explaining the
replacement.

**Why this priority**: Reactor-wide defaults are the main source of unpredictable retries.
Removing them first also makes the rest of this feature simpler: once they are gone, a step's
policy can only come from two places (its step block or its step class), so no later story
has to decide how a step class policy ranks against a reactor default, or whether it depends
on where the defaults line sits in the reactor. This story is delivered and verified on its
own, before any step class declaration work starts (see Delivery order).

**Independent Test**: Define a reactor that uses the removed reactor-wide defaults declaration
and confirm it fails to load with a message naming the reactor and pointing to step-level
`retries`. Then define a reactor whose steps declare no policy and confirm each failing step
is attempted exactly once.

**Acceptance Scenarios**:

1. **Given** a reactor that declares reactor-wide retry defaults, **When** the reactor class is
   loaded, **Then** loading fails with a message naming the reactor, stating that reactor-wide
   defaults were removed, and telling the author to declare `retries` on each step class or
   step block that needs it.
2. **Given** a step with no retry declaration in its class or its step block, **When** it
   fails, **Then** it is attempted exactly once and the failure proceeds to rollback.
3. **Given** a reactor that did not use reactor-wide defaults before this change, **When** it
   runs after the change, **Then** every step behaves exactly as before.
4. **Given** nested reactors placed with `compose` or `async_reactor`, **When** their step
   blocks declare no `retries`, **Then** they are attempted once. They no longer read a
   reactor-wide default.

---

### User Story 2 - A step class declares its own retry policy (Priority: P1)

A workflow author writes a step that talks to a flaky external service: charging a card,
calling a partner API, sending an email. The author knows how that operation should be retried
(how many attempts, how far apart), because the author knows the service. Today that
knowledge can only be written in each reactor that uses the step, so every reactor has to
repeat it and can get it wrong.

The author declares the retry policy in the step class, next to its inputs and its lock. Any
reactor that uses the step gets that policy without mentioning it.

**Why this priority**: This is the main feature. Without it, the step is not a complete unit
of work: part of how it should run still lives in every caller. It builds on US1: by the
time it starts, reactor-wide defaults no longer exist.

**Independent Test**: Define a step class that declares three attempts and fails on its first
two runs. Place it in a reactor with no retry wiring and confirm the step succeeds on its third
attempt. Then make it fail on every run and confirm the workflow fails after exactly three
attempts.

**Acceptance Scenarios**:

1. **Given** a step class declaring a maximum of N attempts, **When** a reactor uses the step
   without any retry wiring and the step fails with a retryable failure, **Then** the step is
   attempted again, up to N attempts in total.
2. **Given** the same step, **When** an attempt succeeds before N attempts are used,
   **Then** the workflow continues with that attempt's result and makes no further attempts.
3. **Given** the same step, **When** all N attempts fail, **Then** the step's failure reports
   the step name and the number of attempts made, and rollback proceeds as for any step
   failure.
4. **Given** a step class declaring a backoff strategy and base delay, **When** attempts are
   retried, **Then** the wait between attempts follows that strategy and delay.
5. **Given** a step class declaring retries with only some options (for example only the
   number of attempts), **When** it runs, **Then** the options it left out take the same
   defaults the reactor-side `retries` uses today.
6. **Given** a step fails with a failure marked as not retryable, **When** its class declares
   retries, **Then** it is not attempted again, exactly as with reactor-side retries today.

---

### User Story 3 - Existing step-level declarations keep working unchanged (Priority: P1)

Authors already declare retries in a reactor's step block, for inline steps and for class
steps. Both keep working exactly as they do today. The class-level declaration is the
preferred form for class steps, not a replacement.

**Why this priority**: Inline steps are a supported style, and existing step-block
declarations must not break.

**Independent Test**: Run the existing step-level retry tests unchanged and confirm they pass.
Then declare `retries` inside an inline step block and confirm the behavior matches the class
form.

**Acceptance Scenarios**:

1. **Given** an inline step that declares `retries` and a `run` body in its block, **When** it
   fails, **Then** it is retried according to that declaration, exactly as today.
2. **Given** a class step that declares no retries, **When** its reactor step block declares
   `retries`, **Then** the step-block declaration applies, exactly as today.
3. **Given** an inline step and a class step with the same retry declaration, **When** both
   fail the same way, **Then** their attempt counts, delays, and final outcome are the same.
4. **Given** an inline step's `retries` line, **When** the author moves the step into a class,
   **Then** the same line works unchanged in the class body.

---

### User Story 4 - One declaration per step (Priority: P1)

A step's policy is declared in exactly one place. Declaring it in the step class and again in
the reactor's step block for that class is refused when the reactor is defined, the same way a
lock declared in both places is refused today.

**Why this priority**: If both declarations were accepted silently, one would be ignored and
the author would not know which. That is how retries end up wrong in production.

**Independent Test**: Declare retries on a step class, then add a `retries` line to a
reactor's step block for that class. Confirm the reactor fails to load with a message naming
the reactor, the step, and the class, and explaining how to resolve it.

**Acceptance Scenarios**:

1. **Given** a step class declaring retries, **When** a reactor also declares `retries` in that
   step's block, **Then** the reactor is refused at definition time with a message naming the
   reactor, the step, and the class, and telling the author to keep only one declaration.
2. **Given** a step class that declares no retries, **When** a reactor declares `retries` in
   its step block, **Then** no conflict is raised (US3 scenario 2).
3. **Given** a step class declaring a single attempt, **When** it runs, **Then** it is not
   retried. Declaring one attempt is a valid, explicit "do not retry".

---

### User Story 5 - The policy follows the step on every execution path (Priority: P2)

A step class's retry policy applies wherever the step runs: in the calling process, in a
background worker after the whole reactor is handed off, after a mid-workflow hand-off, as an
independently dispatched step, and after the workflow resumes from an interrupt. Attempts
already made are remembered when a retry is scheduled for later, so the attempt limit holds
across those gaps.

**Why this priority**: A policy that only applies on some paths is a trap, and background runs
are where retries matter most. But the synchronous path alone already delivers value.

**Independent Test**: Run the same reactor with the same always-failing class step
synchronously and in the background. Confirm both make exactly the declared number of
attempts, and that the background run schedules later attempts without blocking the worker.

**Acceptance Scenarios**:

1. **Given** a class step with a declared policy in a reactor that runs in the calling process,
   **When** it fails, **Then** retries wait in-process between attempts, as reactor-side
   retries do today.
2. **Given** the same step in a reactor that runs in a background worker, **When** it fails,
   **Then** the next attempt is scheduled for later instead of blocking the worker, as
   reactor-side retries do today.
3. **Given** the same step placed as an independently dispatched step, **When** it fails,
   **Then** its declared policy governs its retries.
4. **Given** a retry scheduled for later, **When** the next attempt runs, **Then** the attempts
   already made count toward the limit, and the workflow never exceeds the declared maximum.
5. **Given** a step that exhausts its attempts in any of these paths, **When** it fails for the
   last time, **Then** earlier steps compensate exactly as they do for reactor-side retries.

---

### User Story 6 - Step subclasses inherit the policy (Priority: P2)

A team keeps a base step class for all calls to one partner API, with the retry policy that
API needs. Each concrete step inherits that policy. A subclass that needs a different policy
declares its own, and this does not change its parent or its siblings.

**Why this priority**: Step inheritance is already supported for inputs and locks. Retries
must behave the same way, but the feature works without it.

**Independent Test**: Declare retries on a base step class, subclass it twice, override the
policy in one subclass, and confirm each class runs with the expected policy.

**Acceptance Scenarios**:

1. **Given** a base step class declaring retries, **When** a subclass declares none, **Then**
   the subclass runs with the base policy.
2. **Given** a subclass that declares its own retries, **When** it runs, **Then** its own
   policy applies, and the base class and other subclasses keep the base policy.
3. **Given** a reactor needs a different policy for a class step that already declares one,
   **When** the author subclasses the step and declares the new policy there, **Then** the
   reactor uses the subclass with no conflict. This is the documented way to vary the policy
   per workflow.

---

### User Story 7 - Tests and operators can see the policy (Priority: P2)

A developer writing a spec for a reactor uses the shipped test helpers to check that a
class-declared policy was applied: how many times a step was retried, and that it failed or
succeeded afterward. Operators and tooling can find out what retry policy a step will run with
and where it was declared.

**Why this priority**: Required by the project's testing and observability rules. The feature
works without it, but cannot be verified or debugged without it.

**Independent Test**: Write a reactor spec using only the shipped test surface that makes a
class step fail and asserts it was retried the declared number of times. Then look up the
step's effective policy from the reactor and confirm it reports the class as its source.

**Acceptance Scenarios**:

1. **Given** a class step with a declared policy, **When** it fails in a test using the shipped
   test helpers, **Then** the existing retry assertions report the attempts it made.
2. **Given** a class step whose body is replaced by a test mock, **When** the mock fails,
   **Then** the class's declared policy still applies, so tests exercise the real policy.
3. **Given** any step in a reactor, **When** its effective retry policy is looked up, **Then**
   the answer includes the maximum attempts, backoff, base delay, and whether it came from the
   step class, the step block, or no declaration.
4. **Given** a class step being retried, **When** instrumentation is enabled, **Then** each
   retry attempt is reported with the step name and attempt number, exactly as for
   reactor-side retries today.

---

### Edge Cases

- **Invalid values**: an unknown backoff strategy, a negative delay, or an attempt count that
  is not a positive whole number is refused when the step class (or inline step) is defined,
  naming the step and the bad value. Today an unknown backoff strategy only fails at the first
  retry, in production.
- **Direct invocation**: a step class that declares retries is called directly from
  application code, or from another step's body, not through a reactor. The call runs once
  and its retries do not apply: only a reactor coordinates retries. A failure is returned to
  the caller straight away. This differs on purpose from locks, which a direct call does take.
- **Reactor subclasses and test doubles**: a reactor subclass, or a test copy of a reactor
  made by the shipped test helpers, must not bring back reactor-wide defaults by copying them
  from a parent.
- **Retries and locks**: a step class declares both a lock and retries. Their combined behavior
  must be the same as when the same two declarations are made on the reactor side today. This
  feature changes where the policy is declared, not how retries use locks.
- **Retries and input validation**: a step whose inputs fail its own contract is not retried.
  Invalid inputs will not become valid on another attempt, and today reactor-side retries do
  not retry contract failures either.
- **Skipped steps**: a step skipped by a condition or guard makes no attempts and uses none of
  its retry budget.
- **Policy changed between attempts**: a retry scheduled for later runs under the policy in the
  code that the worker is running. Attempts already made still count.
- **Duck-typed implementations**: a step implementation that is not a step class has no class
  policy. Only its step-block declaration applies, and without one it runs once.
- **Nested reactors and map elements**: `compose`, `async_reactor`, and `map` place reactors,
  not step classes. Their step-block `retries` declarations keep working. A step class used
  inside a nested or mapped reactor brings its own policy there too.

## Requirements *(mandatory)*

### Functional Requirements

#### Declaration

- **FR-001**: A step class MUST be able to declare its retry policy (maximum attempts, backoff
  strategy, base delay) using the same `retries` vocabulary and defaults as the reactor-side
  step block.
- **FR-002**: An inline step MUST keep being able to declare `retries` in its reactor step
  block, with identical behavior to the class form.
- **FR-003**: A class step that declares no retries MUST keep accepting a `retries`
  declaration in its reactor step block, with today's behavior.
- **FR-004**: Invalid retry values MUST be refused at definition time, in either form, with a
  message naming the step and the offending value.

#### Removal of reactor-wide defaults

- **FR-005**: The reactor-wide retry defaults declaration MUST be removed. A reactor that uses
  it MUST fail to load with a message naming the reactor, stating that the declaration was
  removed, and telling the author to declare `retries` on each step class or step block that
  needs it. This follows how other removed reactor declarations are handled.
- **FR-006**: No step, nested reactor, or dispatched unit MAY take its retry policy from its
  reactor. The only sources are the step class and the step block.
- **FR-007**: A step with no retry declaration in either place MUST be attempted exactly once.

#### Precedence and conflicts

- **FR-008**: A step's effective policy MUST come from its step block if it declares one,
  otherwise from its step class, otherwise no retries.
- **FR-009**: Declaring `retries` both on a step class and in a reactor's step block for that
  class MUST be refused at reactor definition time, with a message naming the reactor, the
  step, and the class, and telling the author to keep one declaration. This matches how
  conflicting lock declarations are refused.

#### Inheritance

- **FR-010**: A step subclass MUST inherit its parent's retry policy unless it declares its
  own. Redeclaring MUST NOT affect the parent or its siblings.

#### Execution

- **FR-011**: A class-declared policy MUST apply on every path a reactor-side policy applies
  to today: the calling process, background hand-off of the whole reactor or part of it,
  independently dispatched steps, and runs resumed after an interrupt or a scheduled retry.
- **FR-012**: Retry behavior under a class-declared policy MUST match a step-block declaration
  with the same values: which failures are retried, attempt counting across scheduled
  retries, the wait between attempts, in-process waiting versus scheduling for later, the
  final failure report, and compensation after the last attempt.
- **FR-013**: A direct invocation of a step class (outside any reactor, including from
  another step's body) MUST run exactly once and MUST NOT apply the class's retry policy. Only
  a reactor coordinates retries. Documentation MUST state this, and MUST state that it differs
  from locks, which a direct call does take.

#### Visibility and verification

- **FR-014**: A step's effective retry policy and its source (step class, step block, or none)
  MUST be available to tooling and tests.
- **FR-015**: The shipped test surface MUST verify class-declared retries with the existing
  retry assertions, including when the step's body is replaced by a test mock.
- **FR-016**: Retry attempts under a class-declared policy MUST produce the same
  instrumentation events and failure details as step-block retries.

#### Delivery order

- **FR-017**: The removal of reactor-wide defaults (US1, FR-005 to FR-007) MUST be delivered
  first as a standalone change: removal, removal error, rewritten tests, documentation and
  migration note, with the full suite passing. Step class declarations (US2 onward) MUST start
  only after that change is complete, and MUST NOT include any handling of reactor-wide
  defaults.

#### Delivery

- **FR-018**: The feature MUST ship a runnable demo reactor, a demo task, and a spec that uses
  only the shipped test surface. Together they MUST show a class step that succeeds after
  retries, a class step that exhausts its retries and triggers compensation, and a step with
  no declaration that is attempted once.
- **FR-019**: Documentation MUST present the step class form as the preferred way to declare
  retries, and MUST state the precedence order, the conflict rule, and how to vary a policy per
  workflow by subclassing. Every example that uses reactor-wide defaults MUST be rewritten to
  step-level declarations.
- **FR-020**: The release MUST carry a migration note explaining the removal of reactor-wide
  defaults and showing how to move each default onto the steps that need it.

### Key Entities

- **Retry Policy**: how a step is re-attempted after a retryable failure. Attributes: maximum
  attempts, backoff strategy (exponential, linear, fixed), base delay.
- **Policy Source**: where a step's effective policy came from. One of: step block (inline or
  reactor-side), step class, or none.
- **Attempt Record**: the per-execution count of attempts made for each step. It is kept
  across scheduled retries and hand-offs, and checked against the effective policy's maximum.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A step class that declares its retry policy can be used in any number of reactors
  with zero retry lines in those reactors, and gets the same policy in each.
- **SC-002**: Every existing step-level retry test passes unchanged. Tests that exercised
  reactor-wide defaults are replaced by tests of the removal error.
- **SC-003**: For the same failure sequence, a class-declared policy and a step-block
  declaration with the same values produce the same attempt count, the same waits between
  attempts, and the same final outcome, on both the in-process and the background paths.
- **SC-004**: A step's retry policy can be determined by reading only that step's class or
  step block, in 100% of cases.
- **SC-005**: 100% of reactors still using reactor-wide defaults, and 100% of conflicting
  double declarations (class plus step block), are refused when the reactor loads. None reach
  run time.
- **SC-006**: 100% of invalid retry values are refused when the step is defined. None surface
  first at a retry in production.
- **SC-007**: A developer can find a step's effective policy and where it was declared without
  reading the step or reactor source.
- **SC-008**: The demo runs end to end in the project's container setup and shows the
  succeed-after-retry, exhaust-and-compensate, and single-attempt outcomes.

## Assumptions

- The audience is developers writing reactors and steps with this library.
- The feature changes where the retry policy is declared, not how retries run. The runtime
  behavior of retries (retryable failures, backoff formulas, attempt counting, scheduling in
  background runs) is reused unchanged.
- Delivering the removal first is deliberate: it deletes the reactor-default fallback before
  a second source of policy (the step class) is added, so the new work only ever deals with
  two sources and needs no ordering or precedence rules involving the reactor.
- Removing reactor-wide defaults is a breaking change to the public API. It is released under
  the project's versioning policy for breaking changes, with a migration note. It follows the
  existing pattern for removed declarations: the old call raises a clear error at load time
  instead of being silently ignored.
- A reactor that never declared reactor-wide defaults already runs undeclared steps once, so
  it sees no behavior change.
- The conflict rule for class-plus-step-block declarations follows the existing rule for
  conflicting lock declarations: refuse, don't silently choose one. To use a different policy
  in one workflow, the author subclasses the step (US6 scenario 3). There is no per-reactor
  override of a class policy.
- The step-block `retries` form stays fully supported for inline steps, for class steps that
  declare no policy, and for `compose`, `async_reactor`, and `map`. It is not deprecated in
  this feature.
- Refusing invalid values at definition time tightens the inline form slightly. A value that
  fails at the first retry today will fail when the reactor loads instead. Values that work
  today keep working, with one exception: an attempt count of zero, which today silently means
  "do not retry", must now be written as one.
- Step inheritance works for retries the same way it already works for inputs and locks.
