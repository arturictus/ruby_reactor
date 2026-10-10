# frozen_string_literal: true

# Loaded only when `config.storage.adapter = :active_record` (011 R-01): this
# file and storage/active_record/ are ignored by Zeitwerk, so a Redis-only app
# never loads ActiveRecord.
begin
  require "active_record"
rescue LoadError
  raise LoadError, "config.storage.adapter = :active_record needs the activerecord gem: add " \
                   '`gem "activerecord", ">= 8.0"` (and a database driver) to your Gemfile'
end

if ActiveRecord.gem_version < Gem::Version.new("8.0")
  raise LoadError, "config.storage.adapter = :active_record needs activerecord >= 8.0 " \
                   "(found #{ActiveRecord.gem_version})"
end

require "digest"
require "json"

module RubyReactor
  module Storage
    # Reactor state and coordination in a relational database (PostgreSQL,
    # MySQL, SQLite) instead of Redis. See specs/011-active-record-adapter.
    class ActiveRecordAdapter < Adapter
      SCHEMA_VERSION = 1

      def self.migrations_path = File.expand_path("active_record/migrations", __dir__)
    end
  end
end

%w[record models coordination contexts step_results maps map_rollback claims locking ordered_locking].each do |file|
  require_relative "active_record/#{file}"
end

module RubyReactor
  module Storage
    class ActiveRecordAdapter
      include Contexts
      include StepResults
      include Maps
      include MapRollbacks
      include Claims
      include Locking
      include OrderedLocking

      # `database`: a database.yml name (Symbol), a URL or a Hash; nil means the
      # host's primary database. Either way the adapter gets its own pool.
      CONNECT_LOCK = Mutex.new

      def initialize(database: nil)
        super()
        self.class.connect(database || ::ActiveRecord::Base.connection_db_config)
      end

      # (Re)points the shared pool only when the config changes: re-running
      # establish_connection drops the live pool, which would fail any thread
      # mid-query with ConnectionNotDefined.
      def self.connect(config)
        CONNECT_LOCK.synchronize do
          return if @connected_config == config

          Record.establish_connection(config)
          @connected_config = config
        end
      end

      def purge_expired_coordination(limit: 1000)
        Coordination.purge_expired(limit: limit)
      end

      # No push channel: completion signals are a latency optimisation only,
      # and AsyncWaiter's fallback re-check of the durable record carries
      # correctness (R-14). The waiter kills this thread when it is done.
      def publish(_channel, _message)
        nil
      end

      def subscribe(_channel)
        loop { sleep 3600 }
      end

      private

      # Every operation leases a connection only for its own duration, so
      # long-lived threads (lock auto-extend, heartbeats) never pin one.
      def with_db(&) = Record.connection_pool.with_connection(&)

      # Update-then-insert, portable across engines: last writer wins, and
      # `insert_only` columns are written once. A racing insert falls back to
      # the update.
      def write_row(model, key, attrs, insert_only: {})
        return if model.where(key).update_all(attrs).positive?

        model.insert!(key.merge(attrs).merge(insert_only))
      rescue ::ActiveRecord::RecordNotUnique
        model.where(key).update_all(attrs)
      end
    end
  end
end

# The RSpec storage reset is installed at RSpec.configure time, which can run
# before this adapter is first selected and loaded. Guarded on RSpec itself so
# production never autoloads the test helpers.
RubyReactor::RSpec::StorageReset.install! if defined?(::RSpec::Core)
