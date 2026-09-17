# Phase 1 Data Model: Step Input Contracts

**Feature**: `specs/002-step-input-contracts/` | **Date**: 2026-09-10

Everything here is definition-time state held on Ruby classes. Nothing new is persisted to
Redis; resolved argument values continue to round-trip through `ContextSerializer` exactly as
today.

## InputDeclaration

One declared value of one unit of work. Produced by `input` in a step class or inside an
inline step's `inputs do` block.

| Field | Type | Default | Notes |
|---|---|---|---|
| `name` | Symbol | — | Required. Unique within a contract; a redeclaration replaces the earlier one. |
| `type` | Symbol \| Module \| nil | `nil` | `:string`/`:integer`/`:decimal`… → dry-schema positional type. A Module → `type?: Klass` instance check. `nil` → no type constraint. |
| `optional` | Boolean | `false` | `false` → `required(name).filled(...)`. `true` → `optional(name).maybe(...)`. |
| `default` | Object \| nil | `nil` | Applied when the key is absent or resolves to `nil`. Never applied for `false` (FR-023). Mutually meaningful only with `optional: true`. |
| `redact` | Boolean | `false` | Value is masked in failures and logs (FR-015). |
| `predicates` | Hash | `{}` | dry-schema predicates: `gt?`, `gteq?`, `min_size?`, `max_size?`, `included_in?`, … |
| `macro_block` | Proc \| nil | `nil` | Form-2 block: `input :x do |i| i.filled(:string) end`. Bound to the value macro. |
| `schema` | Object \| nil | `nil` | Form-3 pre-built schema/contract via `validate:`. |

**Validation rules**: `name` must be a Symbol; exactly one of `predicates`+`type`,
`macro_block`, or `schema` shapes the rule (matching the reactor's existing `input` dispatch in
`Dsl::Reactor::ClassMethods#build_input_validator_for`); `default` without `optional: true`
raises at declaration time.

## InputContract

The full set of declarations owned by one unit of work, plus the compiled validator.

| Field | Type | Notes |
|---|---|---|
| `owner` | Class \| step name | The step class, or the inline step's name. |
| `declarations` | Ordered Hash{Symbol → InputDeclaration} | Declaration order preserved for message stability. |
| `cross_field_block` | Proc \| nil | Cross-field rules over the whole argument hash (FR-002). Composed last, wins on conflict — same precedence as today's `validate_args`. |
| `validator` | `Validation::InputValidator` | Compiled once, lazily, via `SchemaBuilder.build_args(inline_rules, cross_field_block)`. |

**Derived queries** (the introspection surface, FR-014):

- `required_names` → declarations where `optional == false`
- `optional_names`, `defaults`, `redacted_names`
- `declares?(name)`

**Inheritance**: a subclass's contract is `parent.declarations.merge(own.declarations)` — same
name in the subclass replaces the parent's entry (spec Edge Cases). Resolved by walking the
superclass chain at first access, memoized per class.

**State**: `declared` (during class body) → `compiled` (first validation or first
introspection) → immutable. A declaration added after compilation resets to `declared`;
supported so reopened classes behave predictably, not an encouraged pattern.

## ArgumentWiring

The reactor-side binding. Already exists as the entries of `StepConfig#arguments`; this
feature narrows its meaning to source + transform only.

| Field | Type | Notes |
|---|---|---|
| `name` | Symbol | Must match an `InputDeclaration#name` when the step owns a contract (FR-018). |
| `source` | `Template::Input` \| `Template::Result` \| `Template::Value` \| `Template::Element` | Unchanged. Also carries dependency information for the DAG. |
| `transform` | Proc \| nil | Unchanged. Applied after resolution, before validation. |
| `origin` | `:explicit` \| `:inferred` | New. `:inferred` marks a wiring synthesized by the name-based fallback (FR-020), so error messages and the dashboard can say where it came from. |

**Rules**: an `:explicit` wiring is never replaced by an `:inferred` one. Rules and types on an
`argument` are rejected when the step owns a contract (FR-006); still accepted, with a
deprecation notice, when it does not (FR-010).

## ContractCheckResult

Definition-time diagnostics. Not persisted — raised as errors.

| Check | When | Raises | FR |
|---|---|---|---|
| Rules declared in both places | `step` macro (`StepBuilder#build`) | `Error::ValidationError` naming reactor, step, argument, owning class | FR-006 |
| `argument` for an undeclared input | `step` macro | `Error::ValidationError` naming the unknown argument | FR-018 |
| Required input neither wired nor name-matched | `Reactor.validate_definition!` | `Error::ValidationError` naming step, input, and both ways to satisfy it | FR-008, FR-021 |
| `default` on a required input | `input` call | `Error::ValidationError` | — |

## Validation failure payload

Unchanged shape — this feature adds sources, not structures. `build_validation_failure`
(`executor/result_handler.rb`) already emits:

| Field | Source |
|---|---|
| `validation_errors` | `InputValidator#format_errors` — flattened `{field => message}` |
| `step_name` | Stamped by `StepExecutor` for class steps (new, D3); set at the raise site for inline steps (existing) |
| `reactor_name` | Existing |
| `step_arguments` | Existing; redacted per `InputDeclaration#redact` |

`have_validation_error(:field)` reads `validation_errors` and therefore works against
contract failures with no matcher change.

## Lifecycle

```text
class body        input :amount, :decimal, gt?: 0   → InputDeclaration
                  ────────────────────────────────    appended to InputContract (declared)

reactor body      step :charge, ChargeStep do
                    argument :amount, input(:amount) → ArgumentWiring(:explicit)
                  end
                  └─ StepBuilder#build ─────────────→ ContractCheckResult (conflict, unknown arg)

first execution   Reactor.validate_definition!      → ContractCheckResult (satisfiability)
                                                    → ArgumentWiring(:inferred) for unwired
                                                      declared inputs matching reactor inputs

per step run      resolve_arguments                 → Hash{name => value} (presence-preserving)
                  contract.validator.call(args)     → Success | raise InputValidationError
                  step body                         → Result
```
