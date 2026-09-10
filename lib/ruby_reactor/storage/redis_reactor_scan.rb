# frozen_string_literal: true

module RubyReactor
  module Storage
    # Listing/scanning reactor contexts for the dashboard/API: a capped
    # single-shot scan (`scan_reactors`, used by the sweeper) and a
    # cursor-paginated variant (`scan_reactors_page`, used by `GET /reactors`
    # so a client can page through a large result set in batches instead of
    # one capped call).
    module RedisReactorScan
      def scan_reactors(pattern: "reactor:*:context:*", count: 50, include_dispatched_children: false)
        # Use SCAN to find keys matching the pattern
        results = []
        batch_keys = []

        # scan_each yields keys. We buffer them to use MGET efficiently.
        # We request a batch size from Redis (count: 100) to reduce roundtrips.
        @redis.scan_each(match: pattern, count: 100) do |key|
          batch_keys << key

          # specific batch size for MGET processing
          if batch_keys.size >= 50
            results.concat(fetch_and_filter_reactors(batch_keys, include_dispatched_children))
            batch_keys = []

            # Stop if we have enough results
            return results.take(count) if results.size >= count
          end
        end

        # Process remaining keys
        results.concat(fetch_and_filter_reactors(batch_keys, include_dispatched_children)) if batch_keys.any?

        results.take(count)
      end

      # `cursor` is an offset into a freshly re-sorted full key scan ("0" for
      # the first page); the returned `cursor` is "0" once there is nothing
      # left to fetch.
      #
      # Redis's own SCAN cursor can't be windowed to exactly `count` items:
      # one `SCAN` call is free to return far more matches than its `count`
      # hint once the keyspace is small (as it is here), so slicing that
      # single batch down to `count` and reporting the raw cursor as the next
      # page silently drops the overflow — a real bug this replaced. Instead
      # we scan the full matching keyspace every call (cheap at dashboard
      # scale), sort it for a stable order across calls, and slice a plain
      # offset window out of it. A page can come back shorter than `count`
      # when some keys in its window get filtered out by
      # `fetch_and_filter_reactors` (dispatched children, non-context keys)
      # — the cursor still advances correctly since it tracks raw key
      # position, not filtered result count.
      def scan_reactors_page(pattern: "reactor:*:context:*", cursor: "0", count: 50, include_dispatched_children: false)
        offset = cursor.to_i
        offset = 0 if offset.negative?

        all_keys = []
        @redis.scan_each(match: pattern, count: 100) { |key| all_keys << key }
        all_keys.sort!

        window = all_keys[offset, count] || []
        next_offset = offset + window.size
        next_cursor = next_offset < all_keys.size ? next_offset.to_s : "0"

        { reactors: fetch_and_filter_reactors(window, include_dispatched_children), cursor: next_cursor }
      end

      def determine_status(data)
        status = data["status"].to_s == "skipped" ? "halted" : data["status"].to_s # "skipped" is the legacy halt name
        return status if %w[failed paused completed running halted pending].include?(status)
        return "cancelled" if data["cancelled"]
        # Heuristic
        return "failed" if data["retry_count"]&.positive? && !data["current_step"].nil?
        return "running" if data["current_step"]
        return "completed" if execution_evidence?(data)

        "pending"
      end

      def execution_evidence?(data)
        (data["execution_trace"] || []).any? ||
          (data["intermediate_results"] || {}).any?
      end

      private

      def fetch_and_filter_reactors(keys, include_dispatched_children = false)
        return [] if keys.empty?

        json_results = @redis.mget(*keys)

        json_results.compact.map do |json|
          data = JSON.parse(json)
          next if data["parent_context_id"] && !(include_dispatched_children && dispatched_child?(data))
          # Skip non-context records (e.g. async_step Step Result Records) whose
          # keys are a "reactor:*:context:*" substring match on the SCAN glob
          # (context:#{id}:step_result:#{name}) but aren't a reactor context.
          next unless data["reactor_class"]

          {
            id: data["context_id"],
            class: data["reactor_class"],
            status: determine_status(data),
            created_at: data["started_at"],
            failure: data["failure_reason"]
          }
        end.compact
      end

      # An `async_reactor` child owns its own job, so a lost job strands it like
      # a top-level reactor. Compose children (inline) and map elements
      # (Map::Sweeper's) carry no marker, so neither is swept.
      def dispatched_child?(data) = data.dig("private_data", "async_dispatched")
    end
  end
end
