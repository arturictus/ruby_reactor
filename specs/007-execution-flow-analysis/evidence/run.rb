# frozen_string_literal: true

# bundle exec ruby specs/007-execution-flow-analysis/evidence/run.rb [| tee …/output.txt]
# PROBE=<substring> limits the run to matching scenario ids.

require_relative "harness"

puts "# Execution-flow probes — #{Time.now.utc.iso8601} — ruby_reactor #{RubyReactor::VERSION} " \
     "(#{`git rev-parse --short HEAD`.strip})"
puts

Dir[File.join(__dir__, "probes", "*.rb")].each { |f| require f }

total = Probe.tally.values.sum
puts "#{total} scenarios, #{Probe.tally[:match]} match, #{Probe.tally[:mismatch]} mismatch"
