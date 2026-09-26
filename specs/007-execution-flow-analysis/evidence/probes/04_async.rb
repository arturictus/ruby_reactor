# frozen_string_literal: true

# async_step / async_reactor: research H19–H22. Parents run inline; units run
# in their own jobs. Reader scenarios use Sidekiq inline! (the unit completes at
# enqueue) because a same-process reader in fake mode would wait out
# async_wait_timeout for a job nobody performs.

module P
  # r reads result(:u); opts in to compensation by failing on a Failure.
  module Reader
    def reader(name, source)
      pstep name do
        argument :seen, result(source)
        run do |inputs, _ctx|
          Probe.rec("run:#{name}")
          failed = inputs.seen.is_a?(RubyReactor::Failure)
          failed ? RubyReactor.Failure("#{name} saw a failed unit") : RubyReactor.Success(inputs.seen)
        end
      end
    end
  end

  class Async01 < Base
    pstep :a
    pstep :u, kind: :async_step, after: :a, fail: true
    pstep :b, after: :a
  end

  class Async02 < Base
    extend Reader

    pstep :a
    pstep :u, kind: :async_step, after: :a, fail: true
    reader :r, :u
  end

  class Async03 < Base
    pstep :a
    pstep :u, kind: :async_step, after: :a
    pstep :b, after: :a, fail: true
  end

  class Async04 < Base
    pstep :a
    async_reactor(:child, ChildFails) { argument :from_a, result(:a) }
    pstep :b, after: :a
  end

  class Async05 < Base
    extend Reader

    pstep :a
    async_reactor(:child, ChildFails) { argument :from_a, result(:a) }
    reader :r, :child
  end

  class Async06 < Base
    pstep :a
    async_reactor(:child, ChildOk) { argument :from_a, result(:a) }
    pstep :b, after: :a, fail: true
  end

  class Async07 < Base
    pstep :a
    pstep :u, kind: :async_step, after: :a, fail: true, retries: { max_attempts: 3, base_delay: 0 }
    pstep :b, after: :a
  end
end

Probe.scenario "S-async-01", "a → async_step u(fails), no reader; b",
               mode: :"inline parent + drained StepWorker",
               expected: %w[run:a run:b run:u => success] do
  result = P::Async01.run({})
  Probe.drain
  result
end

Probe.scenario "S-async-02", "a → async_step u(fails) → r reads u and fails",
               mode: :"inline parent + Sidekiq inline!",
               expected: %w[run:a run:u run:r compensate:r undo:a => failure(r)] do
  Probe.inline_jobs { P::Async02.run({}) }
end

Probe.scenario "S-async-03", "a → async_step u(ok); b(fails), no reader",
               mode: :"inline parent + drained StepWorker",
               expected: %w[run:a run:b compensate:b undo:a run:u => failure(b)] do
  result = P::Async03.run({})
  Probe.drain
  result
end

Probe.scenario "S-async-04", "a → async_reactor child(c1 → c2 fails), no reader; b",
               mode: :"inline parent + drained Worker",
               expected: %w[run:a run:b run:child.c1 run:child.c2 compensate:child.c2 undo:child.c1 => success] do
  result = P::Async04.run({})
  Probe.drain
  result
end

Probe.scenario "S-async-05", "a → async_reactor child(c1 → c2 fails) → r reads child and fails",
               mode: :"inline parent + Sidekiq inline!",
               expected: %w[run:a run:child.c1 run:child.c2 compensate:child.c2 undo:child.c1 run:r compensate:r
                            undo:a => failure(r)] do
  Probe.inline_jobs { P::Async05.run({}) }
end

Probe.scenario "S-async-06", "a → async_reactor child(ok); b(fails)",
               mode: :"inline parent + drained Worker",
               expected: %w[run:a run:b compensate:b undo:a run:child.c1 run:child.c2 => failure(b)] do
  result = P::Async06.run({})
  Probe.drain
  result
end

Probe.scenario "S-async-07", "a → async_step u(always fails, retries 3), no reader; b",
               mode: :"inline parent + drained StepWorker",
               expected: %w[run:a run:b run:u run:u run:u => success] do
  result = P::Async07.run({})
  Probe.drain
  result
end

# Fake mode: nobody performs the unit, so the same-process reader waits out
# async_wait_timeout (2s here). The unit is drained afterwards.
Probe.scenario "S-async-08", "a → async_step u → r reads u; unit never finishes in time",
               mode: :"inline parent + drained StepWorker (after)",
               expected: %w[run:a undo:a run:u => failure(?)] do
  result = P::Async02.run({})
  Probe.note("error=#{result.error.to_s.lines.first&.strip}")
  Probe.drain
  result
end
