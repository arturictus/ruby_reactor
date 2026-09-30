# frozen_string_literal: true

# background: research H8, H23. The worker path (Worker#perform →
# Executor#resume_execution) against the same shapes as the inline baseline.

module P
  class Bg01 < Base
    background all: true
    pstep :a
    pstep :b, after: :a
    pstep :c, after: :b, fail: true
  end

  class Bg02 < Base
    pstep :a
    pstep :b, after: :a
    pstep :c, after: :b, fail: true
    background after: :a
  end

  class Bg03 < Base
    background all: true
    pstep :a
    pstep :b, after: :a, fail: true, retries: { max_attempts: 3, base_delay: 0 }
  end

  class Bg04 < Base
    background all: true
    pstep :a
    pstep :b, after: :a, fail_times: 1, retries: { max_attempts: 2, base_delay: 0 }
    pstep :c, after: :b
  end
end

Probe.scenario "S-bg-01", "background all: a → b → c(fails)",
               mode: :worker, expected: %w[run:a run:b run:c compensate:c undo:b undo:a => failure(c)] do
  Probe.run_async(P::Bg01)
end

Probe.scenario "S-bg-02", "a | background after: :a | b → c(fails)   (a ran in the caller)",
               mode: :"caller + worker", expected: %w[run:a run:b run:c compensate:c undo:b undo:a => failure(c)] do
  P::Bg02.run({})
  Probe.note("caller returned with #{Probe.pending_jobs} worker job(s) queued")
  id = RubyReactor::Adapters::Sidekiq::Worker.jobs.first["args"].first
  Probe.drain
  P::Bg02.find(id)
end

Probe.scenario "S-bg-03", "background all: a → b(always fails, retries 3)",
               mode: :worker,
               expected: %w[run:a run:b retry:b#1 run:b retry:b#2 run:b compensate:b undo:a => failure(b)] do
  Probe.run_async(P::Bg03)
end

Probe.scenario "S-bg-04", "background all: a → b(fails once, retries 2) → c",
               mode: :worker, expected: %w[run:a run:b retry:b#1 run:b run:c => success] do
  Probe.run_async(P::Bg04)
end
