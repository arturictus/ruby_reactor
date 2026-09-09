# frozen_string_literal: true

class PeriodDemoReactor < RubyReactor::Reactor
  input :org_id, :string
  input :notify, :string, optional: true

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

  # Demonstrates `skip!`: when the caller opts out of notifications, this
  # step does nothing but still hands the published report through to
  # dependants exactly like a Success would — the reactor keeps going.
  step :notify_subscribers do
    argument :notify, input(:notify)
    argument :report, result(:publish_report)
    wait_for :publish_report
    run do |args|
      if args[:notify] == "skip"
        puts "[EXECUTION] PeriodDemoReactor.notify_subscribers - skipped (notify: \"skip\")"
        skip!(args[:report])
      end

      puts "[EXECUTION] PeriodDemoReactor.notify_subscribers - report: #{args[:report]}"
      Success(args[:report])
    end
  end

  returns :notify_subscribers
end
