# frozen_string_literal: true

require "spec_helper"

# US2: a step's `with_lock` protects only that step. `ScopedLockReactor`
# (spec/support/reactors/step_coordination_reactors.rb) is an eight-step
# reactor whose third step is the only one locked (a fixed key, "shared", so
# two concurrent runs genuinely contend on it). Steps 1, 2, 4-8 must keep
# overlapping across two concurrent runs — proving the hold never leaks
# beyond the one step that declared it.
RSpec.describe "step-scoped `with_lock` is scoped to the step, not the reactor", :step_coordination do
  it "lets every step except the locked one overlap across two concurrent runs (US2)" do
    run_id = step_coord_run_id

    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    threads = [
      Thread.new { ScopedLockReactor.run(run_id: run_id) },
      Thread.new { ScopedLockReactor.run(run_id: run_id) }
    ]
    threads.each(&:join)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

    %i[step1 step2 step4 step5 step6 step7 step8].each do |tag|
      expect(overlap_recorder.overlapped?(tag, tag)).to be(true), "expected #{tag} to overlap across the two runs"
    end
    expect(overlap_recorder.max_concurrency(:step3)).to eq(1)

    # SC-002: two concurrent runs, with only step3 serialized, finish well
    # under the fully-serial bound (2x one run's total step time) — proving
    # the lock did not accidentally serialize the whole reactor. Steps 1-3
    # sleep 0.1s each, steps 4-8 sleep 0.4s each (single_run_total below).
    single_run_total = (0.1 * 3) + (0.4 * 5)
    expect(elapsed).to be < (single_run_total * 2)
  end

  it "lets run A's step4 start before run B's step3 starts, while B waits on step3 (US2-2)" do
    run_id = step_coord_run_id

    # Run A takes the lock first (starts first); run B starts shortly after
    # and must queue on step3 while A is still inside it.
    thread_a = Thread.new { ScopedLockReactor.run(run_id: run_id) }
    sleep 0.05
    thread_b = Thread.new { ScopedLockReactor.run(run_id: run_id) }
    [thread_a, thread_b].each(&:join)

    a_step4_start = overlap_recorder.entries(:step4).map { |e| e[:timestamp] }.min
    b_step3_entries = overlap_recorder.entries(:step3).map { |e| e[:timestamp] }.sort
    # The second (later) step3 interval belongs to run B, since run A's
    # step3 interval necessarily starts first (A started first).
    b_step3_start = b_step3_entries.last(2).min

    expect(a_step4_start).to be < b_step3_start
  end
end
