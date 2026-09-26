# frozen_string_literal: true

# Interrupts, manual cancel/undo, failure kinds and crash re-drive:
# research H2 (worker), H5 contrast, H24 (pause), H26–H28.

module P
  class Intr01 < Base
    with_lock { |_inputs| "rk" }
    pstep :a
    interrupt(:approval) { wait_for :a }
    pstep :c, after: :approval, fail: true
  end

  class Intr02 < Base
    pstep :a
    interrupt :approval do
      wait_for :a
      max_attempts 1
      validate_payload { required(:ok).filled(:bool) }
    end
    pstep :c, after: :approval
  end

  class Intr03 < Base
    pstep :a
    interrupt(:approval) { wait_for :a }
    pstep :c, after: :approval
  end

  class Intr04 < Base
    with_lock { |_inputs| "rk" }
    pstep :a
    pstep :b, after: :a
  end

  # A worker-side step whose lock stays contended past lock_snooze_max_attempts.
  class Edge01 < Base
    background all: true
    pstep :a
    pstep(:b, after: :a) { with_lock { |_args| "sk" } }
  end

  class Crash < Exception; end # rubocop:disable Lint/InheritException

  class Edge02 < Base
    background all: true
    pstep :a
    pstep :b, after: :a do
      run do |_inputs, _ctx|
        Probe.rec("run:b")
        raise Crash, "worker killed" if (Probe.counters[:crash] += 1) == 1

        RubyReactor.Success("b")
      end
    end
    pstep :c, after: :b
  end

  class Edge03 < Base
    pstep :a
    pstep :b, after: :a, fail: :raise do
      run do |_inputs, _ctx|
        Probe.rec("run:b")
        raise Crash, "non-StandardError"
      end
    end
  end

  class Edge04 < Base
    pstep :a
    pstep(:b, after: :a) { where { |_ctx| raise "where boom" } }
  end

  class Edge05 < Base
    pstep :a
    pstep :b, after: :a do
      inputs { input :x, :string }
      argument :x, value(5)
    end
  end

  class Edge06 < Base
    input :n, :integer
    pstep :a
  end
end

def status_of(klass, id) = "status=#{klass.find(id).context.status}"

Probe.scenario "S-intr-01", "reactor with_lock(rk): a → interrupt → [continue] → c(fails)",
               mode: :inline,
               expected: %w[lock_acquired:rk run:a lock_released:lock:rk lock_acquired:rk run:c compensate:c undo:a
                            lock_released:lock:rk => failure(c)] do
  paused = P::Intr01.run({})
  Probe.note("first run => #{Probe.outcome(paused)}")
  P::Intr01.continue(id: paused.execution_id, step_name: :approval, payload: { ok: true })
end

Probe.scenario "S-intr-02", "a → interrupt(validate, max_attempts 1) ← invalid payload",
               mode: :inline, expected: %w[run:a undo:a => failure(approval)] do
  paused = P::Intr02.run({})
  P::Intr02.continue(id: paused.execution_id, step_name: :approval, payload: { ok: "nope" })
end

Probe.scenario "S-intr-03", "a → interrupt → Reactor.cancel",
               mode: :inline, expected: %w[run:a => status=cancelled] do
  paused = P::Intr03.run({})
  P::Intr03.cancel(id: paused.execution_id, reason: "user gave up")
  status_of(P::Intr03, paused.execution_id)
end

Probe.scenario "S-intr-04", "completed a → b; reactor lock rk held by another owner; Reactor.undo(id)",
               mode: :inline, expected: %w[lock_acquired:rk run:a run:b lock_released:lock:rk undo:b undo:a
                                           => status=cancelled] do
  done = P::Intr04.run({})
  P.hold_lock("rk", "someone-else")
  P::Intr04.undo(done.execution_id)
  status_of(P::Intr04, done.execution_id)
end

Probe.scenario "S-edge-01", "background all: a → b(step lock held elsewhere; lock_snooze_max_attempts 2)",
               mode: :worker, expected: %w[run:a undo:a => failure(b)] do
  RubyReactor.configuration.lock_snooze_max_attempts = 2
  P.hold_lock("sk", "someone-else")
  Probe.run_async(P::Edge01)
ensure
  RubyReactor.configuration.lock_snooze_max_attempts = 20
end

Probe.scenario "S-edge-02", "background all: a → b(worker crashes once) → c; job redelivered",
               mode: :worker, expected: %w[run:a run:b crash run:b run:c => success] do
  P::Edge02.run({})
  job = RubyReactor::Adapters::Sidekiq::Worker.jobs.first.dup
  begin
    Probe.drain
  rescue P::Crash
    Probe.rec("crash")
  end
  RubyReactor::Adapters::Sidekiq::Worker.new.perform(*job["args"])
  Probe.drain
  P::Edge02.find(job["args"].first)
end

Probe.scenario "S-edge-03", "a → b(raises a non-StandardError Exception)",
               mode: :inline, expected: %w[run:a run:b => raised(P::Crash)] do
  P::Edge03.run({})
rescue P::Crash
  "raised(P::Crash)"
end

Probe.scenario "S-edge-04", "a → b(where-condition raises)",
               mode: :inline, expected: %w[run:a compensate:b undo:a => failure(b)] do
  P::Edge04.run({})
end

Probe.scenario "S-edge-05", "a → b(argument type check fails)",
               mode: :inline, expected: %w[run:a undo:a => failure(b)] do
  P::Edge05.run({})
end

Probe.scenario "S-edge-06", "reactor input validation fails",
               mode: :inline, expected: %w[=> failure(?)] do
  P::Edge06.run({ n: "not a number" })
end
