# frozen_string_literal: true

class PeriodDemoReactor < RubyReactor::Reactor
  input :org_id do
    required(:org_id).filled(:string)
  end

  with_period(every: :day) { |inputs| "daily_report:#{inputs[:org_id]}" }

  step :build_report do
    argument :org_id, input(:org_id)
    run do |args|
      puts "[EXECUTION] PeriodDemoReactor.build_report - org_id: #{args[:org_id]}"
      Success(built: true, org_id: args[:org_id])
    end
  end

  step :publish_report do
    argument :report, result(:build_report)
    wait_for :build_report
    run do |args|
      puts "[EXECUTION] PeriodDemoReactor.publish_report - report: #{args[:report]}"
      Success(published: true, report: args[:report])
    end
  end

  returns :publish_report
end
