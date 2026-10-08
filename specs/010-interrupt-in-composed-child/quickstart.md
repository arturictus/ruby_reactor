# Quickstart: Validating Interrupt Inside a Composed Child

## Prerequisites

- Test Redis on `localhost:6780` (`docker start ruby_reactor_redis_test` if the container exists).
- `bundle install` at the repo root and in `demo_app/`.

## 1. Gem specs

```bash
bundle exec rspec spec/ruby_reactor/interrupt_in_compose_spec.rb   # new: US1–US4, edge cases
bundle exec rspec spec/map/map_compose_fan_out_spec.rb             # FR-015: the former `pending` example
bundle exec rspec spec/ruby_reactor/interrupt_spec.rb spec/ruby_reactor/multiple_interrupts_spec.rb \
  spec/ruby_reactor/interrupt_undo_spec.rb spec/ruby_reactor/interrupt_background_resume_spec.rb \
  spec/integration/interrupt_validation_spec.rb spec/integration/interrupt_max_attempts_spec.rb \
  spec/compose_spec.rb                                             # no regression
bundle exec rspec && bundle exec rubocop                           # full gate
```

Expected:

| Scenario | Outcome |
| --- | --- |
| Root composing a child with `c1`, `interrupt :approve`, `c2` | `paused`; `execution_id` is the root's; `c2` and later root steps not run |
| `Root.continue(id:, payload:, step_name: [:c, :approve])` | `completed`; each step ran once; same result as an uninterrupted run |
| Two composes deep | `ready_interrupt_steps == [[:c, :c, :approve]]` (path through both composes) |
| `continue` with `:approve` or a wrong path | `ValidationError` listing `[[:c, :approve]]`; still `paused` |
| `Child.continue(id: <child id>, …)` | `ValidationError` "is a composed child" |
| `Root.undo(id)` while paused | `undo:child.c1` before `undo:r1`, each once; `cancelled` |
| Invalid payload, `max_attempts: 1` | rolled back from the root; `failed` |
| `resume: :background` on the child interrupt | root's worker runs the remainder; the child is never enqueued |
| `interrupt` inside a map element (direct or via compose) | element fails with "not supported inside a map element" |

## 2. Demo app (Constitution VI)

Fast local loop (test Redis DB 5, no Docker):

```bash
cd demo_app
REDIS_URL=redis://localhost:6780/5 RAILS_ENV=test bundle exec rspec spec/reactors/composed_approval_reactor_spec.rb
REDIS_URL=redis://localhost:6780/5 bin/rails demo:composed_interrupt
```

The rake task prints the pause (status, root id, pending path `[:approval, :wait_for_manager]`),
then the outcome of an approved resume (`completed`) and of a rejected one (`undo` → `cancelled`,
with the child's step undone).

Acceptance run (isolated compose project; see the per-worktree note in the repo memory):

```bash
docker compose -p rr_interrupt_compose -f docker-compose.yml -f <override.yml> up -d --build demo-redis demo-sidekiq
docker compose -p rr_interrupt_compose -f docker-compose.yml -f <override.yml> \
  run --rm --no-deps demo-app bash -c "bin/rails db:prepare && bin/rails demo:composed_interrupt"
```

## 3. Docs check

- `documentation/composition.md`: the "not supported yet" sentence is gone, and the nested pause
  is described.
- `documentation/interrupts.md`: has a "Interrupts inside composed reactors" section with the path
  form, undo and correlation behavior.
- `README.md` Interrupts section: one line pointing to it.
- `CHANGELOG.md` *Unreleased → Features*: the entry is there.
- `specs/future_improvements.md`: the "Interrupt inside a composed child" entry is removed.
