# frozen_string_literal: true

module RubyReactor
  module Error
    # Base for the internal "this execution parks" signals raised inside a
    # worker (`inline_async_execution`). Never persisted, never reaches a
    # synchronous caller.
    #
    # Contract: every rescue between the raise site and the final handler
    # (`Worker#perform`, or `Map::ElementExecutor` for a map element) either
    # re-raises it untouched, or parks its own holds and then re-raises. The
    # requeue happens once, at the top, after every executor on the stack has
    # parked and saved.
    class ExecutionParked < Base; end
  end
end
