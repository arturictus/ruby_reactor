# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

namespace :build do
  desc "Build the UI assets"
  task :ui do
    puts "Building UI..."
    system("cd gui && npm install && npm run build") || abort("UI build failed")

    # Copy assets to public
    # Vite builds to dist by default. We want it in lib/ruby_reactor/web/public
    # Actually, we should configure Vite to build to the right place or copy it.
    # Let's copy.
    FileUtils.rm_rf("lib/ruby_reactor/web/public")
    FileUtils.mkdir_p("lib/ruby_reactor/web/public")
    FileUtils.cp_r("gui/dist/.", "lib/ruby_reactor/web/public/")
    puts "UI built and assets copied to lib/ruby_reactor/web/public"
  end
end

require "rubocop/rake_task"

RuboCop::RakeTask.new

task default: %i[spec rubocop]
