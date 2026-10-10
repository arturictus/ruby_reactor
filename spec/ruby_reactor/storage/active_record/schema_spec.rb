# frozen_string_literal: true

require "spec_helper"
require "stringio"

# 011 FR-019, R-16: the installed schema version is the default of
# ruby_reactor_schema.version; a missing or mismatched schema fails at the
# adapter's first use, before anything is read or written.
RSpec.describe "ActiveRecord storage schema", :active_record_only do # rubocop:disable RSpec/DescribeClass
  let(:adapter_class) { RubyReactor::Storage::ActiveRecordAdapter }
  let(:url) { RubyReactor.configuration.storage.database }
  let(:connection) { ActiveRecord::Base.lease_connection }
  let(:tables) do
    %w[ruby_reactor_schema ruby_reactor_executions ruby_reactor_execution_inputs ruby_reactor_step_results
       ruby_reactor_map_operations ruby_reactor_map_elements ruby_reactor_map_results ruby_reactor_map_rollbacks
       ruby_reactor_map_rollback_outcomes ruby_reactor_correlation_ids ruby_reactor_interrupt_resumes
       ruby_reactor_period_markers ruby_reactor_idempotency_keys ruby_reactor_coordination]
  end

  # Every example leaves the suite's schema as it found it.
  after do
    StorageSelection.rebuild_schema!(adapter_class.migrations_path)
    connection.schema_cache.clear!
    adapter_class::Record.connection_pool.schema_cache.clear!
  end

  def installed_default
    connection.columns("ruby_reactor_schema").find { |column| column.name == "version" }.default.to_i
  end

  def set_version(version)
    connection.change_column_default(:ruby_reactor_schema, :version, version)
    adapter_class::Record.connection_pool.schema_cache.clear!
  end

  it "installs every table, with the gem's version as the marker default" do
    expect(tables - connection.tables).to be_empty
    expect(installed_default).to eq(adapter_class::SCHEMA_VERSION)
    expect(adapter_class::Schema.count).to eq(0) # the marker is a default, never a row
  end

  it "accepts a database built from a dumped db/schema.rb (db:prepare, db:test:prepare)" do
    dump = StringIO.new
    ActiveRecord::SchemaDumper.dump(connection.pool, dump)
    tables.each { |table| connection.drop_table(table) }
    ActiveRecord::Migration.suppress_messages { eval(dump.string) } # rubocop:disable Security/Eval

    expect { adapter_class.new(database: url) }.not_to raise_error
  end

  it "keeps seeded history readable once installed" do
    adapter = adapter_class.new(database: url)
    adapter.store_context("seeded", { "context_id" => "seeded", "reactor_class" => "X" }.to_json, "X")

    expect(adapter.retrieve_context("seeded", "X")).to include("context_id" => "seeded")
  end

  it "fails with the install command when the tables are missing, writing nothing" do
    connection.drop_table(:ruby_reactor_schema)

    expect { adapter_class.new(database: url) }
      .to raise_error(RubyReactor::Error::StorageSchemaError, /missing.*generate ruby_reactor:install/)
    expect(adapter_class::Execution.count).to eq(0)
  end

  it "fails with both versions and the upgrade steps when the schema is behind the gem" do
    set_version(0)

    expect { adapter_class.new(database: url) }.to raise_error(
      RubyReactor::Error::StorageSchemaError,
      /version 0, this gem needs #{adapter_class::SCHEMA_VERSION}: run `bin\/rails generate ruby_reactor:install` then `bin\/rails db:migrate`/
    )
    expect(adapter_class::Execution.count).to eq(0)
  end

  it "fails telling you to upgrade the gem when the schema is ahead of it" do
    set_version(adapter_class::SCHEMA_VERSION + 1)

    expect { adapter_class.new(database: url) }
      .to raise_error(RubyReactor::Error::StorageSchemaError, /newer than this gem's.*upgrade the ruby_reactor gem/)
    expect(adapter_class::Execution.count).to eq(0)
  end
end
