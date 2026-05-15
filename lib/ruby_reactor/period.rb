# frozen_string_literal: true

module RubyReactor
  # Calendar-aligned bucket helpers for `with_period` dedup gating.
  #
  # A *bucket* is a deterministic string derived from the current UTC time and
  # the configured period. Two calls in the same bucket dedup to the same
  # Redis marker key; calls that cross a calendar boundary land in different
  # buckets and run again.
  module Period
    SYMBOLIC_PERIODS = {
      minute: 60,
      hour: 60 * 60,
      day: 60 * 60 * 24,
      week: 60 * 60 * 24 * 7,
      month: 60 * 60 * 24 * 31,
      year: 60 * 60 * 24 * 366
    }.freeze

    # Build the bucket id for a given period at a given moment. UTC, calendar
    # aligned for symbolic periods, index-based for integer seconds.
    def self.bucket_id(every, now: Time.now.utc)
      case every
      when :minute then now.strftime("%Y-%m-%dT%H-%M")
      when :hour   then now.strftime("%Y-%m-%dT%H")
      when :day    then now.strftime("%Y-%m-%d")
      when :week   then now.strftime("%G-W%V")
      when :month  then now.strftime("%Y-%m")
      when :year   then now.strftime("%Y")
      when Integer
        raise ArgumentError, "Period seconds must be positive" unless every.positive?

        "i#{now.to_i / every}"
      else
        raise ArgumentError, "Unknown period: #{every.inspect}"
      end
    end

    # TTL for the marker. Twice the period length so the marker survives clock
    # skew across the boundary and reliably dedups the very next attempt.
    def self.ttl_seconds(every)
      base = period_seconds(every)
      base * 2
    end

    def self.period_seconds(every)
      case every
      when Symbol
        SYMBOLIC_PERIODS.fetch(every) do
          raise ArgumentError, "Unknown period: #{every.inspect}"
        end
      when Integer
        raise ArgumentError, "Period seconds must be positive" unless every.positive?

        every
      else
        raise ArgumentError, "Unknown period: #{every.inspect}"
      end
    end

    def self.key(base, every, now: Time.now.utc)
      "period:#{base}:#{bucket_id(every, now: now)}"
    end
  end
end
