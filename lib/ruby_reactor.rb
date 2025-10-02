# frozen_string_literal: true

require "concurrent"
require "zeitwerk"

# Load dry-validation if available (for validation features)
begin
  require "dry-validation"
rescue LoadError
  # dry-validation is optional, validation features won't be available
end

loader = Zeitwerk::Loader.for_gem
loader.setup

module RubyReactor
  # Success/Failure pattern for results
  class Success
    attr_reader :value

    def initialize(value = nil)
      @value = value
    end

    def success?
      true
    end

    def failure?
      false
    end
  end

  class Failure
    attr_reader :error

    def initialize(error)
      @error = error
    end

    def success?
      false
    end

    def failure?
      true
    end
  end

  # Global helper methods
  def self.Success(value = nil)
    Success.new(value)
  end

  def self.Failure(error)
    Failure.new(error)
  end
end
