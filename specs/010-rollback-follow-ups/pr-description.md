# PR draft: 010 Rollback and Resume Follow-ups

## Baseline (T002)

Before any change, `bundle exec rspec` on `5ca7d1d1`: **1479 examples, 0 failures, 2 pending**
(the two pending are the 009 `map_compose_fan_out_spec` interrupt-inside-composed-child examples).

## Regression proofs

- **US1 (T014)**: with `Executor#execute`'s liveness lock removed, 5 of the 7 examples in
  `spec/ruby_reactor/caller_process_liveness_spec.rb` fail (the sweep re-enqueues the live run, the
  killed run is never seen as live, a manual undo interleaves).
- **US2 (T018)**: with the same line removed, the owner Worker started by the map's completion
  writes the run four times while the caller is still inside `execute`
  (`spec/ruby_reactor/executor/caller_save_race_spec.rb`, "Reactor.run" example). With it, the
  Worker snoozes without reading or writing and the run finishes once.
