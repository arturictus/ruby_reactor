# frozen_string_literal: true

# Baseline: plain steps, one reactor, inline. Research H1–H6.

module P
  class Plain01 < Base
    pstep :a
    pstep :b, after: :a, fail: true
    pstep :c, after: :b
  end

  class Plain02 < Base
    pstep :a
    pstep :b, after: :a, fail: :raise
    pstep :c, after: :b
  end

  class Plain03 < Base
    pstep :a
    pstep :b, after: :a, fail: true, compensate: :fail
  end

  class Plain04 < Base
    pstep :a
    pstep :b, after: :a, undo: :raise
    pstep :c, after: :b, fail: true
  end

  class Plain05 < Base
    pstep :a
    pstep :b, after: :a do
      run do |_inputs, _ctx|
        Probe.rec("run:b")
        RubyReactor.Halt(reason: "enough")
      end
    end
    pstep :c, after: :b
  end

  class Plain06 < Base
    pstep :a
    pstep :b, after: :a do
      run do |_inputs, _ctx|
        Probe.rec("run:b")
        RubyReactor.Skipped("nothing to do")
      end
    end
    pstep :c, after: :b, fail: true
  end

  # An argument transform raising a plain StandardError: resolution happens
  # outside the step's rescue (StepExecutor#execute_step).
  class Plain07 < Base
    pstep :a
    pstep :b do
      argument :x, result(:a), transform: ->(_value) { raise ArgumentError, "transform boom" }
    end
  end

  class Plain08 < Base
    pstep :a
    pstep :b, after: :a do
      validate_output :integer
    end
  end

  # DAG: a and b independent, c needs both, d fails.
  class Plain09 < Base
    pstep :a
    pstep :b
    pstep :c, after: %i[a b]
    pstep :d, after: :c, fail: true
  end
end

Probe.scenario "S-plain-01", "a → b(returns Failure) → c",
               mode: :inline, expected: %w[run:a run:b compensate:b undo:a => failure(b)] do
  P::Plain01.run({})
end

Probe.scenario "S-plain-02", "a → b(raises) → c",
               mode: :inline, expected: %w[run:a run:b compensate:b undo:a => failure(b)] do
  P::Plain02.run({})
end

Probe.scenario "S-plain-03", "a → b(fails, its compensate fails)",
               mode: :inline, expected: %w[run:a run:b compensate:b undo:a => failure(b)] do
  Probe.rollback_note(P::Plain03.run({}))
end

Probe.scenario "S-plain-04", "a → b(undo raises) → c(fails)",
               mode: :inline, expected: %w[run:a run:b run:c compensate:c undo:b undo:a => failure(c)] do
  Probe.rollback_note(P::Plain04.run({}))
end

Probe.scenario "S-plain-05", "a → b(Halt) → c",
               mode: :inline, expected: %w[run:a run:b => halt] do
  P::Plain05.run({})
end

# 008 R-19: `Skipped` is only an instrumentation mark — undone like a Success.
Probe.scenario "S-plain-06", "a → b(Skipped) → c(fails)",
               mode: :inline, expected: %w[run:a run:b run:c compensate:c undo:b undo:a => failure(c)] do
  P::Plain06.run({})
end

Probe.scenario "S-plain-07", "a → b(argument transform raises StandardError)",
               mode: :inline, expected: %w[run:a undo:a => failure(b)] do
  result = P::Plain07.run({})
  Probe.note("error=#{result.error.to_s.lines.first&.strip}")
  result
end

Probe.scenario "S-plain-08", "a → b(output fails validate_output)",
               mode: :inline, expected: %w[run:a run:b compensate:b undo:a => failure(b)] do
  P::Plain08.run({})
end

Probe.scenario "S-plain-09", "DAG a, b → c → d(fails)",
               mode: :inline,
               expected: %w[run:a run:b run:c run:d compensate:d undo:c undo:b undo:a => failure(d)] do
  P::Plain09.run({})
end
