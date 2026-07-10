# frozen_string_literal: true

require "vcr"

# Deliberately UNLIKE RubyLLM's VCR defaults. RubyLLM sets
# `allow_http_connections_when_no_cassette = true` and `record: :once`, so a
# spec with no cassette silently hits the live API. On a bench whose headline
# metric is token cost, that is a footgun, not a convenience.
VCR.configure do |config|
  config.cassette_library_dir = "spec/fixtures/vcr_cassettes"
  config.hook_into :webmock
  config.configure_rspec_metadata!

  # webmock/rspec (required from spec_helper.rb) already blocks outbound HTTP
  # for every example. VCR must not punch a hole in that by falling through to
  # a real request the moment a cassette is missing -- a spec with no cassette
  # and no cache of a real interaction has no business reaching the network.
  config.allow_http_connections_when_no_cassette = false

  config.default_cassette_options = {
    # Recording is an explicit act, never a side effect of running the suite.
    # `LAIN_RECORD=1 bundle exec rspec` flips every :vcr example to
    # :new_episodes for that run; every other run replays only what is already
    # committed, and an unmatched request raises instead of going out.
    record: ENV["LAIN_RECORD"] == "1" ? :new_episodes : :none,
    # VCR's own default, kept EXPLICIT rather than implied: matching only on
    # method + URI means a cassette replays against WHATEVER request body we
    # send, so replaying green can never catch a request-payload regression.
    # That job belongs to `forked.encode(req) == sdk.encode(req)`, the
    # dry-diff against the SDK oracle (see the plan's "Testing strategy" --
    # this is deliberate, not an oversight).
    match_requests_on: %i[method uri]
  }

  # Copied from RubyLLM's filter list, which is thorough.
  config.filter_sensitive_data("<ANTHROPIC_API_KEY>") { ENV.fetch("ANTHROPIC_API_KEY", nil) }

  %w[Authorization Anthropic-Organization-Id Request-Id Cf-Ray].each do |header|
    config.filter_sensitive_data("<#{header.upcase.tr("-", "_")}>") do |interaction|
      interaction.request.headers[header]&.first || interaction.response.headers[header]&.first
    end
  end
end

# A cassette is committed YAML holding FULL request and response bodies. Never
# record one against real medical content -- it is permanent, replayable, and
# invisible once merged, which is the same rule as "PHI must never enter
# memory," and for the same reason. Synthetic prompts only.
