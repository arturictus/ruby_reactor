# frozen_string_literal: true

require "spec_helper"
require "digest"
require "yaml"

# 011 FR-018: released migrations are append-only, enforced by checksum.
RSpec.describe "ActiveRecord storage migrations" do # rubocop:disable RSpec/DescribeClass
  let(:dir) { File.expand_path("../../../../lib/ruby_reactor/storage/active_record/migrations", __dir__) }
  let(:locked) { YAML.safe_load_file(File.join(dir, "migrations.lock")) }
  let(:shipped) { Dir[File.join(dir, "*.rb")].map { |path| File.basename(path) }.sort }

  it "pins every shipped migration in migrations.lock" do
    expect(locked.keys.sort).to eq(shipped)
  end

  it "never changes a released migration" do
    changed = shipped.reject { |file| Digest::SHA256.file(File.join(dir, file)).hexdigest == locked[file] }

    expect(changed).to be_empty, "released migrations are append-only; add a new 00N_ migration instead: #{changed}"
  end
end
