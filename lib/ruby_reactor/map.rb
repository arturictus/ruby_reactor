# frozen_string_literal: true

module RubyReactor
  module Map
    # Element jobs one throw enqueues when a fan-out map declares no
    # `batch_size` (009 R-10), forward and rollback alike.
    DEFAULT_BATCH_SIZE = 50
    # Element contexts an inline map's rollback loads per read (009 R-01).
    ROLLBACK_CHUNK = 100

    # One structured key=value line (009 FR-011), as `Executor#log_completion`.
    def self.log(event, **fields)
      line = { event: event, **fields }.map { |key, value| "#{key}=#{value.inspect}" }.join(" ")
      RubyReactor.configuration.logger.info(line)
    end
  end
end
