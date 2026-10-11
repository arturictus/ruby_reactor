# frozen_string_literal: true

# Once-per-year work with `with_period every: :year` (specs/011 US5). The first
# successful run claims the year's bucket and later runs that year halt. A
# failed run (`fail: true`) claims nothing, so the next run still executes. On
# the ActiveRecord storage adapter the marker is permanent and names the run
# that claimed it.
class YearlyReportReactor < RubyReactor::Reactor
  class BuildReportStep < RubyReactor::Step
    input :report_name
    input :fail, optional: true

    def run
      return Failure("report source unavailable for #{inputs.report_name}") if inputs.fail

      Success(report: "#{inputs.report_name} #{Time.current.year}")
    end
  end

  input :report_name
  input :fail, optional: true

  with_period(every: :year) { |inputs| "annual:#{inputs[:report_name]}" }

  step :build_report, BuildReportStep do
    argument :report_name, input(:report_name)
    argument :fail, input(:fail)
  end

  returns :build_report
end
