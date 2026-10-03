# frozen_string_literal: true

module RubyReactor
  module Map
    class Collector
      # Seconds a collector waits for another collector of the same map. One
      # that found the map unsettled releases within milliseconds, and may be
      # the only trigger left for a failure it just deferred (R-04); a holder
      # busy longer is the one applying the map's result.
      COLLECT_LOCK_WAIT = 2

      def self.perform(arguments)
        arguments = Helpers.normalize_arguments(arguments)
        map_id = arguments[:map_id]

        # Serialize concurrent collector deliveries for the SAME map (eager queue +
        # counter-zero trigger + sweeper re-trigger could otherwise all resume the
        # parent at once and both write its context). A dedicated map_collect lock
        # is used rather than the parent's own lock so it never conflicts with the
        # context lock the parent's resume_execution acquires for itself.
        lock = acquire_collect_lock(map_id)
        return if lock == :contended

        begin
          perform_collection(arguments)
        ensure
          lock.release if lock.respond_to?(:release)
        end
      end

      def self.acquire_collect_lock(map_id)
        return :inline if inline_testing_mode?

        lock = RubyReactor::Lock.new(
          "map_collect:#{map_id}",
          owner: SecureRandom.uuid, ttl: RubyReactor.configuration.context_lock_ttl,
          wait: COLLECT_LOCK_WAIT, auto_extend: true
        )
        lock.acquire
        lock
      rescue RubyReactor::Lock::AcquisitionError
        :contended
      end

      def self.inline_testing_mode?
        defined?(Sidekiq::Testing) && Sidekiq::Testing.respond_to?(:inline?) && Sidekiq::Testing.inline?
      end

      # Once every index has a result slot (a value, `_error`, `_halt` or
      # `_skipped`), signal the map's OWNER run — the top-level context —
      # once, and write nothing else (009 R-03, I-1). The owner's Worker
      # resumes, and `MapStep#run` adopts the settled outcome at any
      # composition depth. An atomic map's failure is applied the same way
      # only once every index has settled, so its compensate sees every
      # element that completed, including ones still in flight when it
      # failed. Until then the last element to settle, or the map sweeper,
      # re-triggers this collector.
      def self.perform_collection(arguments)
        map_id = arguments[:map_id]
        parent_reactor_class_name = arguments[:parent_reactor_class_name]
        storage = RubyReactor.configuration.storage_adapter

        metadata = storage.retrieve_map_metadata(map_id, parent_reactor_class_name)
        return unless metadata
        # Judged against the element count, not map_offset (which batching
        # reservation can push past it).
        return if storage.count_map_results(map_id, parent_reactor_class_name) < metadata["count"].to_i
        return unless storage.claim_map_owner_signal(map_id, parent_reactor_class_name)

        signal_owner(metadata, arguments)
      end

      # Metadata written before the upgrade names no owner (S-6): the parent is
      # the owner of a root-level map.
      def self.signal_owner(metadata, arguments)
        owner_id = metadata["owner_context_id"] || metadata["parent_context_id"] || arguments[:parent_context_id]
        owner_class = metadata["owner_reactor_class_name"] || metadata["parent_reactor_class_name"]
        RubyReactor.configuration.logger.info(
          "event=ruby_reactor.map.settled map_id=#{arguments[:map_id].inspect} owner=#{owner_id.inspect}"
        )
        RubyReactor.configuration.async_router.perform_async(owner_id, owner_class)
      end
    end
  end
end
