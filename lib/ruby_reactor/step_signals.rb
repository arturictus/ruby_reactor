# frozen_string_literal: true

module RubyReactor
  # `success!` / `skip!` / `fail!` / `halt!` — end a step body immediately
  # with the matching signal, from any call depth. Mixed into both authoring
  # surfaces (class steps and inline `run` blocks) so the helpers behave
  # identically in either style (contracts/step-helpers.md).
  #
  # Implemented as throw/catch rather than an exception: a `throw` passes
  # straight through `rescue Exception` while `ensure` blocks still run
  # (verified in research.md R2), so a step's own broad rescue cannot swallow
  # the author's intended outcome. For a class-based step, the catching
  # `catch(StepSignals::TAG)` lives on RubyReactor::Step's own class-level
  # `run`/`undo`/`compensate` (so every caller — the executor, the async
  # worker, a direct call — gets identical translation for free); for an
  # inline `run_block`/`compensate_block`/`undo_block` step, it lives at the
  # invocation site in step_executor.rb / compensation_manager.rb.
  module StepSignals
    TAG = :ruby_reactor_step_signal

    def success!(value = nil)
      throw TAG, RubyReactor.Success(value)
    end

    def skip!(...)
      throw TAG, RubyReactor.Skipped(...)
    end

    def fail!(error, **opts)
      throw TAG, RubyReactor.Failure(error, **opts)
    end

    def halt!(reason: nil, **kwargs)
      throw TAG, RubyReactor.Halt(reason: reason, **kwargs)
    end
  end
end
