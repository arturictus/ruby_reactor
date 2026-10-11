# frozen_string_literal: true

require "rails_helper"
require "rails/generators"

# 011 US2: `rails generate ruby_reactor:install` copies the storage migrations
# once, and copies nothing on a re-run.
RSpec.describe "ruby_reactor:install generator" do
  around do |example|
    Dir.mktmpdir { |dir| @root = dir and example.run }
  end

  def install
    Rails.application.load_generators
    Rails::Generators.invoke("ruby_reactor:install", [], destination_root: @root, behavior: :invoke, quiet: true)
    Dir[File.join(@root, "db/migrate/*.rb")]
  end

  it "copies the shipped migration, timestamped and unchanged" do
    copied = install
    shipped = File.join(RubyReactor::Storage::ActiveRecordAdapter.migrations_path, "001_create_ruby_reactor_tables.rb")

    expect(copied.map { |path| File.basename(path) }).to contain_exactly(/\A\d{14}_create_ruby_reactor_tables\.rb\z/)
    expect(File.read(copied.first)).to eq(File.read(shipped))
  end

  it "copies nothing when the migration is already there" do
    first = install
    second = install

    expect(second).to eq(first)
  end
end
