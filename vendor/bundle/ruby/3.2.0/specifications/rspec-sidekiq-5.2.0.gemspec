# -*- encoding: utf-8 -*-
# stub: rspec-sidekiq 5.2.0 ruby lib

Gem::Specification.new do |s|
  s.name = "rspec-sidekiq".freeze
  s.version = "5.2.0"

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.metadata = { "bug_tracker_uri" => "http://github.com/wspurgin/rspec-sidekiq/issues", "changelog_uri" => "http://github.com/wspurgin/rspec-sidekiq/blob/main/CHANGES.md", "homepage_uri" => "http://github.com/wspurgin/rspec-sidekiq", "source_code_uri" => "http://github.com/wspurgin/rspec-sidekiq" } if s.respond_to? :metadata=
  s.require_paths = ["lib".freeze]
  s.authors = ["Aidan Coyle".freeze, "Phil Ostler".freeze, "Will Spurgin".freeze]
  s.date = "2025-07-19"
  s.description = "Simple testing of Sidekiq jobs via a collection of matchers and helpers".freeze
  s.homepage = "http://github.com/wspurgin/rspec-sidekiq".freeze
  s.licenses = ["MIT".freeze]
  s.required_ruby_version = Gem::Requirement.new(">= 2.7".freeze)
  s.rubygems_version = "3.4.20".freeze
  s.summary = "RSpec for Sidekiq".freeze

  s.installed_by_version = "3.4.20" if s.respond_to? :installed_by_version

  s.specification_version = 4

  s.add_runtime_dependency(%q<rspec-core>.freeze, ["~> 3.0"])
  s.add_runtime_dependency(%q<rspec-expectations>.freeze, ["~> 3.0"])
  s.add_runtime_dependency(%q<rspec-mocks>.freeze, ["~> 3.0"])
  s.add_runtime_dependency(%q<sidekiq>.freeze, [">= 5", "< 9"])
  s.add_development_dependency(%q<actionmailer>.freeze, [">= 0"])
  s.add_development_dependency(%q<activejob>.freeze, [">= 0"])
  s.add_development_dependency(%q<activemodel>.freeze, [">= 0"])
  s.add_development_dependency(%q<activerecord>.freeze, [">= 0"])
  s.add_development_dependency(%q<activesupport>.freeze, [">= 0"])
  s.add_development_dependency(%q<debug>.freeze, [">= 0"])
  s.add_development_dependency(%q<ostruct>.freeze, [">= 0"])
  s.add_development_dependency(%q<railties>.freeze, [">= 0"])
  s.add_development_dependency(%q<rspec>.freeze, [">= 0"])
end
