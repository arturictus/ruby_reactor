# frozen_string_literal: true

require "rack/test"

module RSpecMixin
  include Rack::Test::Methods

  def app
    RubyReactor::Web::API
  end
end

RSpec.configure do |config|
  config.include RSpecMixin, type: :request
end
