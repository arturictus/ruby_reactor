# frozen_string_literal: true

require "spec_helper"
require "open3"

# 011 R-01/R-02: ActiveRecord is opt-in, loaded only when selected, and never a
# runtime dependency.
RSpec.describe "ActiveRecord storage adapter loading" do
  def ruby(code, load_path: [])
    lib = File.expand_path("../../../../lib", __dir__)
    args = [RbConfig.ruby, *load_path.flat_map { |dir| ["-I", dir] }, "-I", lib, "-e", code]
    Open3.capture3(*args)
  end

  it "never loads ActiveRecord, or registers the adapter for autoload, under the Redis adapter" do
    _out, err, status = ruby(<<~RUBY)
      require "ruby_reactor"
      RubyReactor.configure { |c| c.storage.adapter = :redis }
      RubyReactor.configuration.storage_adapter
      abort("ActiveRecord loaded") if defined?(ActiveRecord)
      abort("adapter autoloadable") if RubyReactor::Storage.autoload?(:ActiveRecordAdapter)
      abort("adapter defined") if RubyReactor::Storage.const_defined?(:ActiveRecordAdapter, false)
    RUBY

    expect(status).to be_success, err
  end

  it "explains how to fix a missing activerecord gem" do
    no_ar = File.expand_path("../../../fixtures/no_active_record", __dir__)
    _out, err, status = ruby(<<~RUBY, load_path: [no_ar])
      require "ruby_reactor"
      RubyReactor.configure { |c| c.storage.adapter = :active_record }
      begin
        RubyReactor.configuration.storage_adapter
      rescue LoadError => e
        warn(e.message)
        exit 3
      end
    RUBY

    expect(status.exitstatus).to eq(3)
    expect(err).to include("activerecord").and include('gem "activerecord"')
  end

  describe "storage.database forms", :active_record_only do
    let(:adapter_class) { RubyReactor::Storage::ActiveRecordAdapter }
    let(:db_path) { File.expand_path("../../../../tmp/loading_spec.sqlite3", __dir__) }

    # Re-point the shared pool back at the suite's database.
    after { adapter_class.connect(RubyReactor.configuration.storage.database) }

    it "accepts a URL" do
      adapter_class.connect("sqlite3:#{db_path}")

      expect(adapter_class::Record.connection_db_config.database).to eq(db_path)
    end

    it "accepts a Hash" do
      adapter_class.connect({ adapter: "sqlite3", database: db_path })

      expect(adapter_class::Record.connection_db_config.database).to eq(db_path)
    end

    it "accepts the name of a database.yml entry" do
      env = ActiveRecord::ConnectionHandling::DEFAULT_ENV.call
      original = ActiveRecord::Base.configurations
      ActiveRecord::Base.configurations = { env => { "reactor_store" => { "adapter" => "sqlite3",
                                                                          "database" => db_path } } }
      adapter_class.connect(:reactor_store)

      expect(adapter_class::Record.connection_db_config.database).to eq(db_path)
    ensure
      ActiveRecord::Base.configurations = original
    end
  end
end
