# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"
require "ruby_reactor/storage/active_record_adapter"

module RubyReactor
  module Generators
    # `bin/rails generate ruby_reactor:install` copies the ActiveRecord storage
    # migrations this app doesn't have yet into db/migrate (011 R-16). Run it
    # again after upgrading the gem: only the new migrations are copied, and
    # existing files are never touched.
    class InstallGenerator < Rails::Generators::Base
      include ::ActiveRecord::Generators::Migration

      desc "Copies RubyReactor's ActiveRecord storage migrations into db/migrate"
      source_root RubyReactor::Storage::ActiveRecordAdapter.migrations_path

      def copy_migrations
        Dir[File.join(RubyReactor::Storage::ActiveRecordAdapter.migrations_path, "*.rb")].sort.each do |source|
          name = File.basename(source, ".rb").sub(/\A\d+_/, "")
          if Dir[File.join(destination_root, db_migrate_path, "*_#{name}.rb")].any?
            say_status :exist, "#{db_migrate_path}/*_#{name}.rb", :blue
            next
          end

          copy_file File.basename(source), File.join(db_migrate_path, "#{next_migration_number(db_migrate_path)}_#{name}.rb")
        end
      end

      private

      # Two migrations copied in the same second still need distinct versions.
      # (Private: Thor runs every public method as a generator step.)
      def next_migration_number(dirname)
        number = ::ActiveRecord::Generators::Base.next_migration_number(File.join(destination_root, dirname))
        @last_number = [number.to_i, @last_number.to_i + 1].max
        @last_number.to_s
      end
    end
  end
end
