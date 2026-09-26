# frozen_string_literal: true

# map: research H14–H18, user questions Q1 and Q3. Every element reactor runs
# e1 → e2 and both declare undo/compensate; element i == 2 fails at e2.

module P
  FAILS_AT_TWO = ->(inputs) { inputs.i == 2 }
  ITEMS = { items: [0, 1, 2, 3] }.freeze

  class Elem < Base
    tag "e"
    input :i
    input :from_a, optional: true
    pstep :e1, idx: true
    pstep :e2, after: :e1, idx: true, fail: FAILS_AT_TWO
  end

  class ElemOk < Base
    tag "e"
    input :i
    input :from_a, optional: true
    pstep :e1, idx: true
    pstep :e2, after: :e1, idx: true
  end

  # Shared parent shape: a → map :m → b. Fan-out, fail_fast and whether b
  # fails vary per probe. (Parameter names must not shadow the MapBuilder
  # methods `fan_out` / `fail_fast` / `element` used inside the block.)
  def self.map_parent(name, element_class, fanned: false, tolerant: false, b_fails: false)
    klass = Class.new(Base) do
      input :items
      pstep :a
      map :m, element_class do
        source input(:items)
        argument :i, element(:m)
        argument :from_a, result(:a)
        fan_out(fanned)
        fail_fast(!tolerant)
      end
      pstep :b, after: :m, fail: b_fails
    end
    const_set(name, klass)
  end

  map_parent(:Map01, Elem)
  map_parent(:Map02, Elem, tolerant: true)
  map_parent(:Map03, ElemOk, b_fails: true)
  map_parent(:Map04, Elem, fanned: true)
  map_parent(:Map05, Elem, fanned: true, tolerant: true)
  map_parent(:Map06, ElemOk, fanned: true, b_fails: true)

  class ElemRetry < Base
    tag "e"
    input :i
    input :from_a, optional: true
    pstep :e1, idx: true
    pstep :e2, after: :e1, idx: true, fail_times: 1, retries: { max_attempts: 2, base_delay: 0 }
  end

  map_parent(:Map09, ElemRetry, fanned: true)
  map_parent(:Map10, ElemRetry)

  class ElemHalts < Base
    tag "e"
    input :i
    input :from_a, optional: true
    pstep :e1, idx: true
    pstep :e2, after: :e1, idx: true do
      run do |inputs, _ctx|
        Probe.rec("run:e.e2[#{inputs.i}]")
        inputs.i == 1 ? RubyReactor.Halt(reason: "element done early") : RubyReactor.Success(inputs.i)
      end
    end
  end

  map_parent(:Map11, ElemHalts)

  class ElemWithUnit < Base
    tag "e"
    input :i
    input :from_a, optional: true
    pstep :e1, idx: true
    pstep :u, kind: :async_step, after: :e1, idx: true
    pstep :e2, after: :e1, idx: true, fail: ->(inputs) { inputs.i == 1 }
  end

  map_parent(:Map12, ElemWithUnit, fanned: true)

  class ChildWithMap < Base
    tag "child"
    input :items
    pstep :c0
    map :m, Elem do
      source input(:items)
      argument :i, element(:m)
    end
  end

  class Map07 < Base
    input :items
    pstep :a
    compose(:child, ChildWithMap) { argument :items, input(:items) }
  end

  class Kid < Base
    tag "k"
    pstep :k1
  end

  class ElemComposes < Base
    tag "e"
    input :i
    pstep :e1, idx: true
    compose :kid, Kid
    pstep :e2, after: %i[e1 kid], idx: true, fail: FAILS_AT_TWO
  end

  class Map08 < Base
    input :items
    map :m, ElemComposes do
      source input(:items)
      argument :i, element(:m)
    end
  end
end

def elements(*indexes, fail_at: nil)
  indexes.flat_map do |i|
    base = ["run:e.e1[#{i}]", "run:e.e2[#{i}]"]
    i == fail_at ? base + ["compensate:e.e2[#{i}]", "undo:e.e1[#{i}]"] : base
  end
end

Probe.scenario "S-map-01", "a → map(4 elems, inline, fail_fast; elem 2 fails) → b   [Q1]",
               mode: :inline,
               expected: ["run:a", *elements(0, 1, 2, fail_at: 2), "undo:a", "=>", "failure(m)"] do
  P::Map01.run(P::ITEMS)
end

Probe.scenario "S-map-02", "a → map(inline, fail_fast false; elem 2 fails) → b",
               mode: :inline,
               expected: ["run:a", *elements(0, 1, 2, 3, fail_at: 2), "run:b", "=>", "success"] do
  P::Map02.run(P::ITEMS)
end

Probe.scenario "S-map-03", "a → map(inline, all ok) → b(fails)   [Q1: later failure]",
               mode: :inline,
               expected: ["run:a", *elements(0, 1, 2, 3), "run:b", "compensate:b", "undo:a", "=>", "failure(b)"] do
  P::Map03.run(P::ITEMS)
end

Probe.scenario "S-map-04", "a → map(fan_out, fail_fast; elem 2 fails) → b",
               mode: :worker,
               expected: ["run:a", *elements(0, 1, 2, fail_at: 2), "undo:a", "=>", "failure(m)"] do
  Probe.run_async(P::Map04, P::ITEMS)
end

Probe.scenario "S-map-05", "a → map(fan_out, fail_fast false; elem 2 fails) → b",
               mode: :worker,
               expected: ["run:a", *elements(0, 1, 2, 3, fail_at: 2), "run:b", "=>", "success"] do
  Probe.run_async(P::Map05, P::ITEMS)
end

Probe.scenario "S-map-06", "a → map(fan_out, all ok) → b(fails)",
               mode: :worker,
               expected: ["run:a", *elements(0, 1, 2, 3), "run:b", "compensate:b", "undo:a", "=>", "failure(b)"] do
  Probe.run_async(P::Map06, P::ITEMS)
end

Probe.scenario "S-map-07", "a → compose(c0 → map(elem 2 fails))",
               mode: :inline,
               expected: ["run:a", "run:child.c0", *elements(0, 1, 2, fail_at: 2), "undo:child.c0", "undo:a",
                          "=>", "failure(child)"] do
  P::Map07.run(P::ITEMS)
end

Probe.scenario "S-map-08", "map(elem: e1 → compose(k1) → e2; elem 2 fails)",
               mode: :inline,
               expected: ["run:e.e1[0]", "run:k.k1", "run:e.e2[0]", "run:e.e1[1]", "run:k.k1", "run:e.e2[1]",
                          "run:e.e1[2]", "run:k.k1", "run:e.e2[2]", "compensate:e.e2[2]", "undo:k.k1",
                          "undo:e.e1[2]", "=>", "failure(m)"] do
  P::Map08.run(P::ITEMS)
end

Probe.scenario "S-map-04b", "map(fan_out, fail_fast; elem 2 fails), element jobs performed 3,2,1,0",
               mode: :worker,
               expected: ["run:a", *elements(3), *elements(2, fail_at: 2), "undo:a", "=>", "failure(m)"] do
  dispatched = P::Map04.run(P::ITEMS)
  RubyReactor::Adapters::Sidekiq::MapElementWorker.jobs.reverse!
  Probe.drain
  P::Map04.find(dispatched.execution_id)
end

Probe.scenario "S-map-09", "a → map(fan_out; each e2 fails once, retries 2) → b",
               mode: :worker,
               expected: %w[run:a run:e.e1[0] run:e.e2[0] retry:e2#1 run:e.e1[1] run:e.e2[1] retry:e2#1
                            run:e.e2[0] run:e.e2[1] run:b => success] do
  Probe.run_async(P::Map09, { items: [0, 1] })
end

Probe.scenario "S-map-10", "a → map(inline; each e2 fails once, retries 2) → b",
               mode: :inline,
               expected: %w[run:a run:e.e1[0] run:e.e2[0] retry:e2#1 run:e.e2[0] run:e.e1[1] run:e.e2[1] retry:e2#1
                            run:e.e2[1] run:b => success] do
  P::Map10.run({ items: [0, 1] })
end

Probe.scenario "S-map-11", "a → map(inline; elem 1 returns Halt) → b",
               mode: :inline, expected: %w[run:a run:e.e1[0] run:e.e2[0] run:e.e1[1] run:e.e2[1] => halt] do
  P::Map11.run({ items: [0, 1, 2] })
end

Probe.scenario "S-map-12", "a → map(fan_out; element e1 → async_step u, e2; elem 1 fails) → b",
               mode: :worker,
               expected: %w[run:a run:e.e1[0] run:e.e2[0] run:e.e1[1] run:e.e2[1] compensate:e.e2[1] undo:e.e1[1]
                            undo:a run:e.u[0] run:e.u[1] => failure(m)] do
  result = Probe.run_async(P::Map12, { items: [0, 1] })
  Probe.note("StepWorker jobs left after drain: #{RubyReactor::Adapters::Sidekiq::StepWorker.jobs.size}")
  result
end
