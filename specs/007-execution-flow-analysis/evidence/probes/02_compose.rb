# frozen_string_literal: true

# compose: research H10–H13, user question Q2.

module P
  class ChildOk < Base
    tag "child"
    input :from_a, optional: true
    pstep :c1
    pstep :c2, after: :c1
  end

  class ChildFails < Base
    tag "child"
    input :from_a, optional: true
    pstep :c1
    pstep :c2, after: :c1, fail: true
  end

  class Compose01 < Base
    pstep :a
    compose(:child, ChildFails) { argument :from_a, result(:a) }
    pstep :b, after: :child
  end

  class Compose02 < Base
    pstep :a
    compose(:child, ChildOk) { argument :from_a, result(:a) }
    pstep :b, after: :child, fail: true
  end

  class ChildX < Base
    tag "x"
    pstep :x1
    pstep :x2, after: :x1
  end

  class ChildY < Base
    tag "y"
    input :after_x, optional: true
    pstep :y1
    pstep :y2, after: :y1, fail: true
  end

  class Compose03 < Base
    compose :x, ChildX
    compose(:y, ChildY) { argument :after_x, result(:x) }
  end

  class Inner04 < Base
    tag "inner"
    pstep :i1
    pstep :i2, after: :i1, fail: true
  end

  class Outer04 < Base
    tag "outer"
    input :from_a, optional: true
    pstep :o1
    compose(:inner, Inner04) { argument :from_o1, result(:o1) }
  end

  class Compose04 < Base
    pstep :a
    compose(:outer, Outer04) { argument :from_a, result(:a) }
  end

  class ChildFailsOnce < Base
    tag "child"
    pstep :c1
    pstep :c2, after: :c1, fail_times: 1
  end

  # 008 R-14: the child retries its own step; a compose cannot declare retries.
  class ChildRetriesOnce < Base
    tag "child"
    pstep :c1
    pstep :c2, after: :c1, fail_times: 1, retries: { max_attempts: 2, base_delay: 0 }
  end

  class Compose05b < Base
    compose :child, ChildRetriesOnce
    pstep :b, after: :child, fail: true
  end

  class Compose06 < Base
    background all: true
    pstep :a
    compose(:child, ChildOk) { argument :from_a, result(:a) }
    pstep :b, after: :child, fail: true
  end

  class ChildCompensateFails < Base
    tag "child"
    pstep :c1, undo: :raise
    pstep :c2, after: :c1, fail: true
  end

  class ChildHalts < Base
    tag "child"
    pstep :c1
    pstep :c2, after: :c1 do
      run do |_inputs, _ctx|
        Probe.rec("run:child.c2")
        RubyReactor.Halt(reason: "child done early")
      end
    end
  end

  class Compose08 < Base
    pstep :a
    compose(:child, ChildHalts) { argument :from_a, result(:a) }
    pstep :b, after: :child
  end

  class Compose07 < Base
    pstep :a
    compose(:child, ChildCompensateFails) { argument :from_a, result(:a) }
  end
end

Probe.scenario "S-compose-01", "a → compose(c1 → c2 fails) → b",
               mode: :inline,
               expected: %w[run:a run:child.c1 run:child.c2 compensate:child.c2 undo:child.c1 undo:a
                            => failure(child)] do
  P::Compose01.run({})
end

Probe.scenario "S-compose-02", "a → compose(c1 → c2) → b(fails)",
               mode: :inline,
               expected: %w[run:a run:child.c1 run:child.c2 run:b compensate:b undo:child.c2 undo:child.c1
                            undo:a => failure(b)] do
  P::Compose02.run({})
end

Probe.scenario "S-compose-03", "compose x(x1 → x2) → compose y(y1 → y2 fails)   [Q2]",
               mode: :inline,
               expected: %w[run:x.x1 run:x.x2 run:y.y1 run:y.y2 compensate:y.y2 undo:y.y1 undo:x.x2 undo:x.x1
                            => failure(y)] do
  P::Compose03.run({})
end

Probe.scenario "S-compose-04", "a → compose outer(o1 → compose inner(i1 → i2 fails))",
               mode: :inline,
               expected: %w[run:a run:outer.o1 run:inner.i1 run:inner.i2 compensate:inner.i2 undo:inner.i1
                            undo:outer.o1 undo:a => failure(outer)] do
  P::Compose04.run({})
end

Probe.scenario "S-compose-05", "compose(c1 → c2 fails once) declaring compose-level retries",
               mode: :inline, expected: %w[=> raised(RubyReactor::Error::DeprecatedDslError)] do
  # 008 R-14: a parent never retries a nested reactor as a whole.
  Class.new(P::Base) { compose(:child, P::ChildFailsOnce) { retries max_attempts: 2, base_delay: 0 } }
rescue RubyReactor::Error::DeprecatedDslError
  "raised(RubyReactor::Error::DeprecatedDslError)"
end

Probe.scenario "S-compose-05b", "compose(c1 → c2 fails once, retried by the child) → b(fails)",
               mode: :inline,
               expected: %w[run:child.c1 run:child.c2 retry:c2#1 run:child.c2 run:b compensate:b undo:child.c2
                            undo:child.c1 => failure(b)] do
  P::Compose05b.run({})
end

Probe.scenario "S-compose-06", "background all: a → compose(c1 → c2) → b(fails)",
               mode: :worker,
               expected: %w[run:a run:child.c1 run:child.c2 run:b compensate:b undo:child.c2 undo:child.c1
                            undo:a => failure(b)] do
  Probe.run_async(P::Compose06)
end

Probe.scenario "S-compose-07", "a → compose(c1(undo raises) → c2 fails)",
               mode: :inline,
               expected: %w[run:a run:child.c1 run:child.c2 compensate:child.c2 undo:child.c1 undo:a
                            => failure(child)] do
  Probe.rollback_note(P::Compose07.run({}))
end

Probe.scenario "S-compose-08", "a → compose(c1 → c2 returns Halt) → b",
               mode: :inline, expected: %w[run:a run:child.c1 run:child.c2 run:b => success] do
  P::Compose08.run({})
end
