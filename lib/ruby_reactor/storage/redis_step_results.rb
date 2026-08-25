# frozen_string_literal: true

module RubyReactor
  module Storage
    # The durable outcome of one `async_step`, keyed by (parent context, step
    # name). It lives OUTSIDE the parent's serialized context blob on purpose: a
    # worker writes it concurrently with the still-running parent, and two
    # writers on one blob race.
    #
    # The `dispatched` record is written before the job is enqueued, so it also
    # serves as the re-attach marker on recovery — "a record exists" is
    # exactly the question "was this already dispatched?".
    module RedisStepResults
      def store_step_result(context_id, step_name, record, reactor_class_name)
        key = step_result_key(context_id, step_name, reactor_class_name)
        # Shares context_ttl with the parent: the record must not outlive what it
        # belongs to, and must not expire before it either.
        @redis.set(key, JSON.generate(record), ex: durability_ttl)
      end

      def retrieve_step_result(context_id, step_name, reactor_class_name)
        json = @redis.get(step_result_key(context_id, step_name, reactor_class_name))
        return nil unless json

        JSON.parse(json)
      end

      private

      def step_result_key(context_id, step_name, reactor_class_name)
        "reactor:#{reactor_class_name}:context:#{context_id}:step_result:#{step_name}"
      end
    end
  end
end
