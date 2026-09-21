# Feature Specification: Step Input Contracts

**Feature Branch**: `step_validations`

**Created**: 2026-09-10

**Status**: Draft

**Input**: User description: "We want to improve the structure of validations for steps. Right now validation in steps are declared in the reactor which is not the right place. Steps should be independent units of work and validations should be declared in those units to encapsulate the unit and its inputs. […] the current argument declaration in step covers three functions: 1. declare step dependencies 2. map reactor outputs to expected arguments 3. declare validations. 1 and 2 are clear and should continue to exist, 3rd is convoluted if different validations are declared in a class step and in the step declaration in the reactor. […] Another issue to take into account is the naming: right now the step has `argument` and the RubyReactor::Step would make sense to have `input`."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A step class declares its own input contract (Priority: P1)

A workflow author writes a reusable step as a standalone class. Inside that class they
declare, in one place, every value the step needs: its name, its expected type, whether it
is optional, and the rules it must satisfy. The step is then a self-contained unit — reading
the class alone tells you what it accepts and what it rejects, with no need to open any
reactor that happens to use it.

When the reactor runs that step, the declared contract is enforced before the step's work
begins. If a value is missing or violates a rule, the step fails with a structured
validation error naming the step and the offending fields, and the step's work never runs.

**Why this priority**: This is the core of the feature. Without it the unit of work is not
self-describing, and the same step reused across three reactors can be validated three
different ways.

**Independent Test**: Define a step class with a typed, constrained input contract, run it
from a minimal reactor with (a) conforming values and (b) violating values, and confirm
success in the first case and a step-attributed validation failure in the second — with no
validation rules declared anywhere in the reactor.

**Acceptance Scenarios**:

1. **Given** a step class declaring a required integer input with a minimum bound, **When**
   the reactor supplies a conforming value, **Then** the step runs and receives the value.
2. **Given** the same step class, **When** the reactor supplies a value below the bound,
   **Then** execution fails before the step's work runs, and the failure reports the step
   name and the field-level error.
3. **Given** a step class declaring an optional input, **When** the reactor supplies no
   value for it, **Then** the step runs and that key is absent/nil rather than failing.
4. **Given** a step class declaring an input typed as a specific class, **When** an instance
   of an unrelated class is supplied, **Then** validation fails with a type error for that
   field.
5. **Given** a step class with a cross-field rule spanning two of its inputs, **When** the
   two values are individually valid but jointly invalid, **Then** validation fails with the
   cross-field error.
6. **Given** a step class declaring a required boolean input, **When** the value supplied is
   `false`, **Then** the input counts as provided: validation passes and the step receives
   `false`, not nil.

---

### User Story 2 - The reactor wires values without redeclaring rules (Priority: P1)

A workflow author composes a reactor from step classes. In the reactor they still say where
each value comes from — a reactor input, another step's result, a constant, a transform —
because only the reactor knows the wiring. They do not restate types or rules there; the
step class owns those.

If the author does restate rules for a step class that already declares its own contract,
the system refuses the definition with a message telling them where the contract lives,
instead of silently running two overlapping rule sets.

**Why this priority**: Wiring and validation are different concerns that today share one
call. Splitting them is what removes the class-step-vs-reactor conflict the author
described; without this half, the duplication and its debugging cost remain.

**Independent Test**: Wire a contract-owning step class into a reactor with mapping-only
declarations and confirm it runs; then add a conflicting rule in the reactor and confirm the
definition is rejected with an actionable message.

**Acceptance Scenarios**:

1. **Given** a reactor wiring a contract-owning step class with mapping-only declarations,
   **When** the reactor class is loaded, **Then** it loads without error and the step's own
   contract governs at run time.
2. **Given** a reactor that attaches a type or rule to an argument of a contract-owning step
   class, **When** the reactor class is loaded, **Then** loading fails with an error naming
   the reactor, the step, the argument, and the step class that already owns the contract.
3. **Given** a reactor that attaches a cross-field rule block to a contract-owning step
   class, **When** the reactor class is loaded, **Then** loading fails with the same class of
   error.
4. **Given** a step class that declares no contract at all, **When** the reactor attaches
   types and rules to its arguments, **Then** the definition is accepted and those rules
   govern (unchanged from today's behavior).

---

### User Story 3 - Inline steps keep a single, coherent place for rules (Priority: P1)

Not every step deserves a class. An author writing a short inline step inside a reactor
declares its rules in the step block, because for an inline step the step block *is* the
unit of work. The wording and the rule vocabulary they use there match what they would write
in a step class, so moving an inline step into a class later is a copy, not a rewrite.

**Why this priority**: Inline steps are a first-class authoring style; leaving them without
an answer would push authors to keep rules in the old place and defeat the split.

**Independent Test**: Write an inline step with a typed, constrained input contract and a
cross-field rule, run it with conforming and violating values, then move the same
declarations verbatim into a step class and confirm identical behavior.

**Acceptance Scenarios**:

1. **Given** an inline step declaring its input contract in the step block, **When** the
   reactor runs with violating values, **Then** it fails with the same error shape a step
   class produces.
2. **Given** an inline step's contract declarations, **When** they are moved unchanged into a
   step class and the reactor keeps only the wiring, **Then** the observable behavior for
   both conforming and violating values is identical.

---

### User Story 4 - Missing wiring is caught when the reactor is defined (Priority: P2)

Because a step class states which values it requires, a reactor that forgets to wire one of
them is a mistake that can be reported when the reactor is loaded, not on the unlucky
production run that first reaches that step.

**Why this priority**: High value and cheap once Story 1 exists, but the feature is usable
without it — the missing value would still be caught at run time by the contract itself.

**Independent Test**: Wire a step class but omit one of its required arguments; confirm the
reactor definition is rejected naming the missing argument.

**Acceptance Scenarios**:

1. **Given** a step class with two required inputs, **When** a reactor wires one and has no
   reactor input matching the other by name, **Then** loading the reactor fails naming the
   reactor, the step, and the missing input.
2. **Given** a step class with a required input, **When** the reactor declares a reactor input
   of the same name and wires no argument for it, **Then** loading succeeds and the step
   receives that reactor input's value at run time.
3. **Given** the same step class, **When** a reactor wires an argument the step does not
   declare, **Then** loading the reactor fails naming the unknown argument.
4. **Given** a reactor that wires no arguments at all for a step that declares no contract,
   **When** the reactor is loaded, **Then** today's implicit behavior applies unchanged (an
   inline step's body receives all reactor inputs).
5. **Given** a step class with an optional input and no matching reactor input, **When** a
   reactor omits it, **Then** loading succeeds and the input is absent at run time.
6. **Given** a step input satisfied by a same-named reactor input, **When** the reactor also
   wires an explicit `argument` for it, **Then** the explicit wiring wins.

---

### User Story 5 - Existing reactors keep working through the transition (Priority: P2)

Teams already running RubyReactor have reactors full of rules declared on arguments. Their
code keeps running after upgrading. Where a construct is being retired, they get a clear,
one-time deprecation message that names the file, the reactor, and the step, and says what to
write instead — so the migration can be done step by step rather than in one flag day.

**Why this priority**: Required by the project's versioning commitments; it does not deliver
the new capability but it decides whether the new capability is adoptable.

**Independent Test**: Run an existing reactor that declares argument-level rules on an
inline step, unchanged, and confirm identical results plus (where applicable) a deprecation
notice.

**Acceptance Scenarios**:

1. **Given** an existing reactor declaring rules on arguments of inline steps, **When** it
   runs after the upgrade, **Then** results and error shapes are unchanged.
2. **Given** an existing reactor declaring rules on arguments of a step class that declares
   no contract of its own, **When** it runs after the upgrade, **Then** results are
   unchanged.
3. **Given** a construct scheduled for removal, **When** a reactor using it is loaded, **Then**
   a deprecation notice is emitted once per construct site, naming the replacement.

---

### Edge Cases

- A step class declares a contract and is used by two reactors that need different bounds
  (e.g. one needs `amount > 0`, another `amount > 100`). The author must resolve this by
  writing two steps, parameterizing the step, or relaxing the contract — the system does not
  offer per-reactor overrides. Documentation must state this explicitly, because the desire
  to override is exactly what produced today's conflict.
- A step class inherits from another step class that declares inputs: the subclass's contract
  is the parent's declarations plus its own, with a same-named input in the subclass
  replacing the parent's.
- The same step class is used twice in one reactor under different step names: each use is
  validated independently against the same contract.
- A step's contract declares an input the reactor maps from a prior step whose result is
  `nil` (skipped, halted, or legitimately nil): the required/optional distinction decides
  pass or fail, and the error must name the source step so the cause is findable.
- A supplied value is falsey but present — `false`, `0`, `""`, `[]`. "Provided" MUST mean the
  key exists, never that the value is truthy. Today a `false` reactor input resolves to nil by
  the time a step sees it, which contracts would escalate from a silent wrong value into a
  spurious "must be filled" failure, and would make an optional input's default fire on
  `false`. The same applies to a step *result* of `false` mapped into a later step's input,
  and to a falsey value reached through a nested path.
- Validation runs on every execution path a step can take: inline execution, retried
  attempts, background/async dispatch (validated in the worker), resumed-after-interrupt
  runs, and each iteration of a map.
- A step class declares a contract but the reactor does not run it (condition/guard is
  false): no validation error is produced for a step that never runs.
- The optional validation dependency is not installed: a step class that declares a contract
  must fail loudly at load time with an actionable message, never silently skip its rules.
- A step class is invoked directly in a test or from application code rather than through a
  reactor: the contract still applies, so a direct call and a reactor-run call reject the same
  values. The failure has no reactor name to report, but still names the step and the fields.
- A step declares an input that is neither wired by an `argument` nor matched by a
  same-named reactor input: the reactor fails to load, naming the step, the input, and both
  ways to satisfy it. A step input is never left to resolve to nil at run time.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: A step class MUST be able to declare its complete input contract — name,
  expected type, optionality, and per-field rules — inside the class itself.
- **FR-002**: A step class MUST be able to declare rules that span more than one of its
  inputs, expressed with the same rule vocabulary already used elsewhere in the library.
- **FR-003**: The declared contract MUST be enforced immediately before the step's work runs,
  on every execution path (inline, retry, background/async dispatch, resume after interrupt,
  and each map iteration).
- **FR-004**: A contract violation MUST produce a failure that (a) prevents the step's work
  from running, (b) identifies the reactor and the step, and (c) exposes field-level errors in
  the same structured shape as today's validation failures, so existing failure handling and
  test matchers keep working.
- **FR-005**: Reactor-side argument declarations MUST continue to declare step dependencies
  and map values (reactor inputs, prior step results, constants, transforms) to step
  argument names.
- **FR-006**: When a step class declares its own contract, the reactor MUST NOT be able to
  attach types, per-field rules, or cross-field rule blocks to that step; attempting to do so
  MUST fail when the reactor class is loaded, with a message naming the reactor, step,
  argument, and the step class that owns the contract.
- **FR-007**: An inline step MUST be able to declare an input contract using the same
  vocabulary a step class uses, such that moving the declarations into a step class requires
  no rewriting of the rules.
- **FR-008**: When a reactor wires a step class that declares a contract, the system MUST
  verify at reactor-load time that every required input of that step is wired, failing with a
  message naming the reactor, step, and missing input.
- **FR-009**: Reactor-level `input` declarations and their validation MUST remain unchanged;
  this feature changes only the step layer.
- **FR-010**: Reactors that declare argument-level rules for inline steps, or for step
  classes that declare no contract, MUST continue to work with unchanged behavior and error
  shapes.
- **FR-011**: Any construct that this feature retires MUST emit a one-time deprecation notice
  per declaration site naming the replacement, and MUST be recorded as a migration note in the
  project changelog.
- **FR-012**: A unit of work declares its contract with `input` — the same word the reactor
  uses for the values *it* requires — in both step classes and inline steps. The reactor-side
  wiring declaration keeps the name `argument`, which from now on means only "where this
  step's value comes from". No existing reactor renames anything.
- **FR-018**: Arguments wired by a reactor for a contract-owning step MUST correspond to
  inputs that step declares; wiring an undeclared argument MUST fail when the reactor is
  loaded, naming the reactor, the step, and the unknown argument.
- **FR-019**: A step that declares no contract and for which the reactor wires no arguments
  MUST keep today's behavior: an inline step's body receives all reactor inputs. This
  implicit path is unaffected by contract declarations on other steps.
- **FR-020**: An input declared by a step and not wired by an `argument` MUST be satisfied
  from the reactor input of the same name, when one exists. The fallback MUST consider
  reactor inputs only — never another step's result — so that resolution never depends on the
  order or naming of other steps. An explicit `argument` for the same name MUST take
  precedence.
- **FR-021**: Every required input of a contract-owning step MUST be resolvable at
  reactor-load time by exactly one of: an explicit `argument`, or a same-named reactor input.
  A required input satisfied by neither MUST fail when the reactor is loaded, with a message
  naming the step, the input, and both ways to satisfy it.
- **FR-022**: A contract MUST be enforced when the step is invoked directly — from a test or
  from application code — not only when a reactor executes it, so that a step rejects the same
  values through every entry point. A direct-invocation failure carries the step name and
  field errors; the reactor name is absent.
- **FR-013**: Optional inputs MUST support being absent, and MUST support a declared default
  value applied before the step's work runs when absent.
- **FR-014**: Contract declarations MUST be introspectable — a step class can be asked which
  inputs it declares, with their types, optionality, and rules — so tooling, the dashboard,
  and reactor-load-time checks can read them.
- **FR-015**: Redaction of sensitive input values in failures and logs MUST be declarable on a
  step's contract, so a step that receives secrets does not leak them through the
  observability surfaces the project requires.
- **FR-016**: Documentation (README and library docs) MUST show the class-step form as the
  primary style, the inline form as its equivalent, and the migration path from
  reactor-declared rules.
- **FR-017**: The feature MUST ship a runnable demo reactor, a `demo:` rake task, and a spec
  using only the shipped test matchers, per the project's demo-app requirement — including
  the failure path where a contract is violated.
- **FR-023**: Presence MUST be determined by whether a value was supplied, not by whether it
  is truthy. A supplied `false` (or any other falsey value) MUST reach the step unchanged,
  MUST satisfy a required input, and MUST NOT trigger an optional input's default. This holds
  for values sourced from reactor inputs, from prior step results, and from nested paths
  within either.

### Key Entities *(include if data involved)*

- **Step Input Contract**: the set of input declarations owned by a unit of work (step class
  or inline step). Attributes: input name, expected type, optionality, default, per-field
  rules, cross-field rules, redaction flag. Owned by exactly one unit; never merged across
  layers.
- **Argument Wiring**: the reactor-side statement binding a step's declared input name to a
  source (reactor input, another step's result, constant, transform). Carries dependency
  information for execution ordering. Contains no rules.
- **Validation Failure**: the structured outcome of a violated contract. Attributes: reactor
  name, step name, field-level errors, redacted values.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A reader can determine every value a step class requires, and the rules on
  each, by reading only that class — verified by the fact that no reactor in the demo app
  declares a rule for any contract-owning step.
- **SC-002**: A step class reused in more than one reactor is validated identically in every
  reactor, with zero per-reactor rule declarations.
- **SC-003**: 100% of conflicting declarations (rules in both the step class and the reactor)
  are reported when the reactor is loaded, not at run time.
- **SC-004**: 100% of unwired required inputs on contract-owning step classes are reported
  when the reactor is loaded, not at run time.
- **SC-005**: Moving an inline step's declarations into a step class requires no change to
  the rule text, and produces identical outcomes for both conforming and violating values.
- **SC-006**: Every existing test in the suite that exercises reactor-declared step rules
  passes unchanged, except those covering constructs explicitly retired with a documented
  migration note.
- **SC-007**: A contract violation reports the reactor, the step, and each offending field, so
  an operator can identify the cause from a single failure record without re-running.
- **SC-008**: The demo app's contract example runs end to end via the documented container
  command, demonstrating both the passing and the failing path.
- **SC-009**: A reactor whose input names already match its steps' declared input names needs
  zero argument declarations to run, and 100% of unsatisfiable required step inputs are
  reported when the reactor is loaded rather than at run time.
- **SC-010**: A step invoked directly and the same step invoked through a reactor accept and
  reject exactly the same values.
- **SC-011**: A boolean input supplied as `false` — sourced from a reactor input, a prior
  step's result, or a nested path — arrives at the step as `false` in 100% of cases, and is
  never reported as missing.

## Assumptions

- The audience is developers authoring reactors and steps with this library; "users" in this
  spec means those developers.
- The existing rule vocabulary (types, predicates such as minimum/maximum/inclusion,
  cross-field rule blocks) is reused as-is; this feature relocates *where* rules are declared
  and *who* owns them, not the rules themselves.
- Step classes that declare no contract remain fully supported; declaring a contract is
  opt-in per step.
- Because a contract is owned by the step, per-reactor overrides are deliberately not offered
  — that capability is the source of the ambiguity this feature removes.
- Composed reactors, map steps, and async/background steps are in scope only insofar as
  contracts must be enforced on their execution paths; their own declaration surfaces are
  unchanged in this feature.
- Output validation (`validate_output`) is out of scope and keeps its current shape and
  location.
- Reactor-level input validation is out of scope and unchanged.
- The optional validation dependency remains optional for the library as a whole; only steps
  that declare a contract require it.
- A unit of work declares its contract with `input`; the reactor's `argument` becomes
  wiring-only. No existing declaration is renamed.
- Correcting falsey-value loss during argument resolution is treated as in-scope for this
  feature rather than a separate fix: contracts make presence semantics load-bearing, so
  shipping them over the current behavior would turn a silent wrong value into a visible
  spurious failure. It is a pre-existing defect, so its correction is a fix, not a breaking
  change.
- Name-based resolution of an unwired step input looks at reactor inputs only. Extending it to
  step results was considered and rejected: it would make a step's wiring depend on the names
  of unrelated steps.
