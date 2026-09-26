# frozen_string_literal: true

# Locks, semaphores and retries relative to rollback: research H2, H7, H13,
# H24, H25. Inline runs unless stated.

module P
  def self.hold_lock(key, owner)
    RubyReactor::Lock.new(key, owner: owner, ttl: 60, wait: 0, auto_extend: false).acquire
  end

  def self.lock_count(key)
    RubyReactor.configuration.storage_adapter.lock_info("lock:#{key}")&.fetch(:count)
  end

  class Lock01 < Base
    with_lock { |_inputs| "rk" }
    pstep :a
    pstep :b, after: :a, fail: true
  end

  class Lock02 < Base
    pstep :a
    pstep(:b, after: :a) { with_lock { |_args| "sk" } }
    pstep :c, after: :b, fail: true
  end

  class Lock03 < Base
    pstep :a
    pstep(:b, after: :a) { with_lock { |_args| "sk" } }
  end

  class Lock04 < Base
    pstep :a
    pstep(:b, after: :a) { with_semaphore(limit: 1) { |_args| "sem" } }
    pstep :c, after: :b, fail: true
  end

  # c's body takes b's key as another owner (a concurrent forward run), so b's
  # undo cannot re-take it within rollback_wait.
  class Lock05 < Base
    pstep :a
    pstep(:b, after: :a) { with_lock(rollback_wait: 0.3) { |_args| "sk" } }
    pstep :c, after: :b do
      run do |_inputs, _ctx|
        Probe.rec("run:c")
        P.hold_lock("sk", "intruder")
        RubyReactor.Failure("boom c")
      end
    end
  end

  class LockedChild < Base
    tag "child"
    with_lock { |_inputs| "rk" }
    pstep :c1
  end

  class Lock06 < Base
    with_lock { |_inputs| "rk" }
    pstep :a
    compose :child, LockedChild
    pstep :b, after: :child do
      run do |_inputs, _ctx|
        Probe.rec("run:b(rk count=#{P.lock_count("rk")})")
        RubyReactor.Failure("boom b")
      end
    end
  end

  class Retry01 < Base
    pstep :a
    pstep :b, after: :a, fail: true, retries: { max_attempts: 3, base_delay: 0 }
  end

  class Retry02 < Base
    pstep :a
    pstep :b, after: :a, retries: { max_attempts: 3, base_delay: 0 } do
      run do |_inputs, _ctx|
        Probe.rec("run:b")
        fail!("permanent", retry: false)
      end
    end
  end

  class Retry03 < Base
    pstep :a
    pstep :b, after: :a, fail_times: 1, retries: { max_attempts: 2, base_delay: 0 }
    pstep :c, after: :b
  end

  class Retry04 < Base
    pstep :a
    pstep :b, after: :a, fail: :raise, retries: { max_attempts: 2, base_delay: 0 }
  end
end

Probe.scenario "S-lock-01", "reactor with_lock(rk): a → b(fails)",
               mode: :inline,
               expected: %w[lock_acquired:rk run:a run:b compensate:b undo:a lock_released:lock:rk => failure(b)] do
  # Reactor-level lock_released reports the prefixed key; lock_acquired does not.
  P::Lock01.run({})
end

Probe.scenario "S-lock-02", "a → b(step with_lock sk) → c(fails)",
               mode: :inline,
               expected: %w[run:a lock_acquired:sk run:b lock_released:sk run:c compensate:c lock_acquired:sk undo:b
                            lock_released:sk undo:a => failure(c)] do
  P::Lock02.run({})
end

Probe.scenario "S-lock-03", "a → b(step with_lock sk, key held by another owner)",
               mode: :inline, expected: %w[run:a undo:a => failure(b)] do
  P.hold_lock("sk", "someone-else")
  P::Lock03.run({})
end

Probe.scenario "S-lock-04", "a → b(step with_semaphore limit 1) → c(fails)",
               mode: :inline,
               expected: %w[run:a semaphore_acquired:sem run:b semaphore_released:sem run:c compensate:c
                            semaphore_acquired:sem undo:b semaphore_released:sem undo:a => failure(c)] do
  P::Lock04.run({})
end

Probe.scenario "S-lock-05", "a → b(step lock sk, rollback_wait 0.3) → c(takes sk as intruder, fails)",
               mode: :inline,
               expected: %w[run:a lock_acquired:sk run:b lock_released:sk run:c compensate:c undo:a
                            => failure(c)] do
  Probe.rollback_note(P::Lock05.run({}))
end

Probe.scenario "S-lock-06", "reactor with_lock(rk): a → compose(child with_lock rk: c1) → b(fails)",
               mode: :inline,
               expected: ["lock_acquired:rk", "run:a", "lock_acquired:rk", "run:child.c1", "lock_released:lock:rk",
                          "run:b(rk count=1)", "compensate:b", "undo:child.c1", "undo:a", "lock_released:lock:rk",
                          "=>", "failure(b)"] do
  P::Lock06.run({})
end

Probe.scenario "S-retry-01", "a → b(always fails, retries 3)",
               mode: :inline,
               expected: %w[run:a run:b retry:b#1 run:b retry:b#2 run:b compensate:b undo:a => failure(b)] do
  P::Retry01.run({})
end

Probe.scenario "S-retry-02", "a → b(fail! retry: false, retries 3)",
               mode: :inline, expected: %w[run:a run:b compensate:b undo:a => failure(b)] do
  P::Retry02.run({})
end

Probe.scenario "S-retry-03", "a → b(fails once, retries 2) → c",
               mode: :inline, expected: %w[run:a run:b retry:b#1 run:b run:c => success] do
  P::Retry03.run({})
end

Probe.scenario "S-retry-04", "a → b(raises, retries 2)",
               mode: :inline, expected: %w[run:a run:b retry:b#1 run:b compensate:b undo:a => failure(b)] do
  P::Retry04.run({})
end
