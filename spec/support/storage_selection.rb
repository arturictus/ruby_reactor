# frozen_string_literal: true

# Picks the storage adapter under test (011 R-17):
#
#   RUBY_REACTOR_TEST_STORAGE=redis|active_record        (default redis)
#   RUBY_REACTOR_TEST_DATABASE_URL=sqlite3:…|postgres://…|trilogy://…
#
# Redis stays up either way: it is the Sidekiq queue and the specs'
# cross-process scratchpad. Under active_record, reactor *storage* never
# touches it.
module StorageSelection
  STORAGE = ENV.fetch("RUBY_REACTOR_TEST_STORAGE", "redis")
  DATABASE_URL = ENV.fetch("RUBY_REACTOR_TEST_DATABASE_URL", "sqlite3:tmp/ruby_reactor_test.sqlite3")

  module_function

  def active_record? = STORAGE == "active_record"

  def configure!(config)
    if active_record?
      config.storage.adapter = :active_record
      config.storage.database = DATABASE_URL
    else
      config.storage.adapter = :redis
      config.storage.redis_url = REDIS_TEST_URL
    end
  end

  # Builds a fresh schema from the shipped migrations, so a suite run always
  # matches the current migration files. ActiveRecord::Base points at the same
  # database for specs that act as the host app (transactions, schema dumps).
  def prepare!
    return unless active_record?

    require "active_record"
    # SQLite creates its file on connect; PostgreSQL/MySQL databases come from
    # docker-compose / CI (POSTGRES_DB, MYSQL_DATABASE).
    FileUtils.mkdir_p("tmp")
    ActiveRecord::Base.establish_connection(DATABASE_URL)
    ActiveRecord::Base.logger = nil
    adapter_class = RubyReactor.configuration.storage_adapter.class
    rebuild_schema!(adapter_class.migrations_path)
  end

  def rebuild_schema!(migrations_path)
    ActiveRecord::Migration.suppress_messages do
      connection = ActiveRecord::Base.lease_connection
      connection.tables.grep(/\Aruby_reactor_/).each { |table| connection.drop_table(table) }
      Dir[File.join(migrations_path, "*.rb")].each do |file|
        require file
        File.basename(file, ".rb").sub(/\A\d+_/, "").camelize.constantize.new.migrate(:up)
      end
    end
  end
end

RSpec.configure do |config|
  config.before(:each, :redis_only) do |example|
    reason = example.metadata[:redis_only]
    skip("Redis-only#{": #{reason}" if reason.is_a?(String)}") if StorageSelection.active_record?
  end

  config.before(:each, :active_record_only) do |example|
    reason = example.metadata[:active_record_only]
    skip("ActiveRecord-only#{": #{reason}" if reason.is_a?(String)}") unless StorageSelection.active_record?
  end
end

# Raw coordination-key access for specs that simulate expiry or inspect TTLs
# (ordered locks, locks): Redis directly, or the ActiveRecord KV that mirrors
# it key for key. Lets those fidelity specs run on both adapters.
module CoordinationProbe
  def coordination(verb, key, *args)
    if StorageSelection.active_record?
      RubyReactor::Storage::ActiveRecordAdapter::Coordination.atomically([key]) do |kv|
        kv.public_send(verb, key, *args)
      end
    else
      redis.public_send(verb == :exists ? :exists? : verb, key, *args)
    end
  end
end

RSpec.configure { |config| config.include CoordinationProbe }
