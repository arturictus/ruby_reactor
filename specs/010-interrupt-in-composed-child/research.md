# Research: Interrupt Inside a Composed Child

Every decision below was taken by reading the code on `main` (5ca7d1d1). Line references are to
that commit.

## R-01: Where the pause breaks today

**Finding**: The child's executor handles its own pause correctly: `handle_interrupt_step` sets the
child's `current_step`, `update_context_status` marks it `paused`, `handle_interrupt` saves it.
The crash comes later, in the parent, at three places that do not know `InterruptResult`:

1. `ComposeStep#handle_execution_result` calls `result.success?` (`compose_step.rb`, last method).
2. `RetryManager#handle_retry_result` falls to `else` and turns it into a `Failure("returned
   unexpected result")`.
3. `ResultHandler#handle_step_result` falls to `handle_unknown_result`, which would record it as a
   completed step.

**Decision**: Pass `InterruptResult` through all three. Each gets one explicit arm.

**Alternatives rejected**: A parent-side exception to unwind the stack (like
`Error::RollbackHandedOff`). An interrupt is a normal result, not an error; `execute_all_steps`
already stops on it (`step_executor.rb:50`), and both `update_context_status` and
`execute_current_step_and_continue` already list it as terminal.

## R-02: The paused result names the root run

**Finding**: The child's `InterruptResult` carries the child's `context_id`. A caller would get an
id that `Root.find` cannot load as the root.

**Decision**: `ComposeStep#handle_execution_result` rebuilds the result with `execution_id:
context.context_id`, the step's own context, keeping `correlation_id`, and passing
`context.intermediate_results`. Each compose level re-stamps its own id, so at any depth the
top-level result carries the root's id.

The root executor's `handle_interrupt` then stores the correlation mapping against the root id
and the root class (`executor.rb:1016`) with no change.

## R-03: The root's resume cursor

**Finding**: `execute_step_sync_without_result_handling` runs the compose body inside
`Context#with_step`, whose `ensure` restores the previous `current_step` (nil) when the body
returns. A root-level interrupt avoids this: `handle_interrupt_step` runs outside `with_step` and
sets `current_step` itself. After a nested pause, the root would have no cursor, and
`Reactor#continue` refuses a context without `current_step`.

**Decision**: The `ResultHandler` arm for `InterruptResult` sets `@context.current_step =
step_config.name`. On resume, `execute_current_step_and_continue` finds the compose step missing
from `intermediate_results`, re-runs it, and `ComposeStep#run` → `execute_child_reactor` sees an
admitted child and calls `resume_execution` on it. The child's own `current_step` is the
interrupt, whose result is now set, so it carries on (`executor.rb:897`).

## R-04: Undo of a run paused inside a child

**Finding**: Rollback replays the undo stack (`CompensationManager#rollback_completed_steps`).
A step joins it only on success (`ResultHandler#handle_success`). The paused compose step never
succeeded, so `Root.undo` would undo `r1` and leave the child's `c1` done. A root-level interrupt
has no such gap, because the interrupt step has no side effects.

The same gap was already closed for an *interrupted* (aborted) compose:
`StepExecutor#track_interrupted_construct` pushes the step with `result: Success(nil)` because
`ComposeStep.undoes_partial_run?` is true, and `ComposeStep#compensate` undoes whatever the child
completed.

**Decision**: The `InterruptResult` arm in `ResultHandler` pushes the same partial-run entry for a
step whose class `undoes_partial_run?`. When that step later completes,
`CompensationManager#add_to_undo_stack` replaces a top entry for the same step instead of
pushing a second one.

- The entry is always the top: the root stops at the pause, so nothing runs after it, and on
  resume the compose step is the first to run.
- Replacing it keeps the undo trace to one `undo:<compose>` per run. Pushing twice would undo the
  compose twice. The second undo would find the child's stack empty, so it would be harmless, but
  still wrong.
- `max_attempts` exhaustion calls `undo` (`reactor.rb:478`), so it is covered by the same entry.

**Alternatives rejected**: Special-casing `Reactor#undo` for a paused run, to compensate the
current compose step first. That is a second rollback path beside the undo stack, and the
max-attempts path would need the same code again.

## R-05: Naming a nested interrupt

**Decision**: A path is an `Array` of two or more names: the compose step names from the root
down, then the interrupt. Symbols and strings are both accepted, so a JSON body works through the
web API's `continue` endpoint. A one-element array is the same as the bare name. A bare name
keeps its current meaning, a step of the root.

**Pending paths**: Derived from the stored state; no new field is stored. For a context and its
reactor class:

1. Take the ready steps from the dependency graph. This is the computation
   `validate_continue_step!` and `TestSubject#ready_interrupt_steps` both do today.
2. Keep the ready interrupt steps, as names.
3. For a ready compose step whose stored child context (`composed_contexts[name][:context]`) is
   `paused`, recurse into the child with its `reactor_class`, prefixing the compose name.

**Decision**: Put this in one public method, `Reactor#ready_interrupt_steps`. It returns Symbols
for root-level interrupts (unchanged for existing callers) and Arrays for nested ones.
`TestSubject#ready_interrupt_steps` delegates to it, which removes the duplicated graph code
there.

**Alternatives rejected**:
- Splat arguments (`be_paused_at(:fulfil, :approve)`): that already means two concurrent root
  interrupts.
- A dotted string `"fulfil.approve"`: step names may contain dots, and Symbol-vs-String parsing
  would leak into every caller.
- Matching a unique bare leaf: a root that later adds a step of that name silently changes what an
  old `continue` call resumes.

**Implementation notes** (added during `/speckit-implement`):

- **Stricter bare names.** `Reactor#continue` now resolves bare names through
  `ready_interrupt_steps` too. The old fast path accepted any `current_step`, and a compose step
  is now a valid `current_step`: `continue(step_name: :fulfil)` would have stored the payload as
  the compose's result and skipped the child. The old wording of the refusal ("expected step 'x'
  or ready steps [...] but got 'y'") is kept, and it lists the pending interrupts.
- **The paused-at interrupt stays pending.** A resume contended on the root's lock leaves its
  payload stored and the run `paused` (`reopen_paused`). That stored payload marks the interrupt
  complete in the graph. So the interrupt a context's `current_step` names stays pending anyway,
  and the retry is accepted, at any depth (`resume_guard_spec.rb` and the nested contention
  example).
- **`Reactor.interrupt_key(step_name)`** (public class method) is the single normalizer: a
  one-name path becomes its Symbol, otherwise an Array of Symbols. `continue`, the test subject
  and the matchers use it.

## R-06: `Reactor#continue` with a path

**Decision**: Resolve the target once, at the top of `continue`: `target_context, step_config,
leaf = resolve_interrupt_target(step_name)`.

- For a bare name it is `@context`, `self.class.steps[name]`, `name`, which is today's behavior.
- For a path it first checks membership in `ready_interrupt_steps`, raising `ValidationError` that
  lists them. It then walks `composed_contexts` down the path and returns the child context, its
  class's step config and the leaf.

The rest of `continue` uses these three instead of `self.class.steps[step_name]` and
`@context.set_result`:

- payload validation;
- the `max_attempts` counter, keyed by the joined path as a Symbol (`:"fulfil.approve"`) for a
  nested interrupt, so it does not share a counter with a root step of the same name. It has to be
  a Symbol: the serializer symbolizes `private_data` keys, so a String key would reset after every
  reload;
- `background_resume?`;
- `set_result`.

Status guards, the `running` claim, `save_context` and `resume_execution` stay on the root
unchanged. So the paused-only guard (008 FR-032), cancel, lock contention (`reopen_paused`) and
background resume (`enqueue_background_resume` enqueues the root) all apply to a nested resume for
free.

## R-07: A child never resumes on its own

**Finding**: The child executor's `save_context` also stores the child under its own id and class
(the observability row), and its `handle_interrupt` maps the correlation id to that row. So
`Child.find(child_id)` loads a `paused` child, and `Child.continue(...)` or
`Child.continue_by_correlation_id(...)` would run it as a standalone run. That breaks the
single-writer rule: the root's embedded copy and the standalone row would diverge.

**Decision**: `ComposeStep#prepare_child_context` marks a new child `private_data[:composed] =
true`; `private_data` is already serialized. `Reactor#continue` raises `ValidationError` on a
context carrying that mark (`"Cannot resume: <class> is a composed child; continue its root
run"`).

- This covers resume by id and by correlation id in one check.
- The child's correlation row stays: the guard makes it harmless, and dropping it would need a
  second check in `handle_interrupt`.
- No stored child predates the mark and can be paused, since a nested pause crashed before this
  feature.

**Alternative rejected**: Guarding on `parent_context_id`. An `async_reactor` child
(`async_reactor_step.rb:175`) sets it too, and that child *is* an addressable run that pauses and
resumes on its own.

## R-08: Interrupt inside a map element

**Finding**: A map element that receives an `InterruptResult` crashes:

- inline: `MapStep#execute_inline_map` calls `result.failure?`;
- fan-out: `ElementExecutor.handle_result` calls `result.halted?`.

This happens today for an `interrupt` directly in an element. After this feature, the same crash
also happens for one reached through a compose inside the element.

**Decision**: `StepExecutor#handle_interrupt_step` fails the step ("interrupt :name is not
supported inside a map element") when the context or any `parent_context` up the chain has
`map_metadata`. The `Failure` goes through `ResultHandler#handle_step_result`, as an
argument-resolution failure does, so the element rolls back what it completed before the
interrupt. The element then fails like any element: an atomic map rolls back, and a
non-atomic one records the error. One check, at the source, covers both map modes and any compose
depth inside the element.

## R-09: Out of scope

- `async_reactor` children are addressable runs of their own and already pause on their own. They
  are unchanged.
- `reconstruct_paused_result` keeps omitting `correlation_id`, for root-level and nested pauses
  alike (spec FR-003).
- The dashboard does not render the nested path. It reads the root's status (`paused`) and
  drills into `composed_contexts` as today.
- Compose steps cannot declare `retries` (008 R-14), so a pause never consumes a retry attempt
  that matters. No decrement is needed.

## R-10: SemVer

The change is MINOR: a previously crashing case now works, plus one additive public method
(`Reactor#ready_interrupt_steps`) and an additive argument form (Array `step_name`). Nothing that
worked changes behavior.
