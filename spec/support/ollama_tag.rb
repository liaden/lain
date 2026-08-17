# frozen_string_literal: true

require "net/http"

# Gating for the :ollama tag -- the local, free, temperature-0 bench arm.
#
# Mirrors spec/support/tags.rb's :api_integration idiom exactly: :ollama examples
# hit a REAL Ollama server on localhost, so they are skipped unless LAIN_OLLAMA=1,
# and they reach the network only through ExampleNetwork (which takes
# NetworkAccess.permit, moving BOTH the WebMock and the VCR switch -- see
# spec/support/network_access.rb -- unless a cassette is in play). Unlike
# :api_integration these cost no money, but they are still nondeterministic and need
# a running server + a pulled model, so the default posture stays offline.
#
#   LAIN_OLLAMA=1 bundle exec rspec spec/integration/provider/ollama_spec.rb
#
# The server base is a spec-level knob (OLLAMA_API_BASE), threaded into both the
# reachability probe and Provider::Ollama.new(api_base:). Note: the LIBRARY does
# NOT read this env var -- Provider::HTTP::Configuration has no ollama_api_base
# ENV default; the base is a constructor/CLI argument (exe/lain --api-base). The
# spec reads the env purely so a developer with a non-default server can point
# the tests at it. Absent the var, everything defaults to http://localhost:11434.
OLLAMA_ENABLED = ENV["LAIN_OLLAMA"] == "1"
OLLAMA_API_BASE = ENV.fetch("OLLAMA_API_BASE", "http://localhost:11434")

# The reachability pre-check. When LAIN_OLLAMA=1 but the server is down or the
# model is not pulled, an :ollama example must SKIP with a message (never fail):
# a missing local server is an environment gap, not a lain regression. Returns a
# human skip reason, or nil when the server is reachable AND the model is present.
module OllamaTestServer
  MODEL = Lain::Provider::Ollama::DEFAULT_MODEL

  def self.unreachable_reason(base: OLLAMA_API_BASE, model: MODEL)
    tags = fetch_tags(base)
    return "Ollama server not reachable at #{base} -- start `ollama serve`" if tags.nil?

    names = Array(tags["models"]).filter_map { |entry| entry["name"] }
    return nil if names.any? { |name| name == model || name.start_with?("#{model}-") }

    "Ollama model #{model.inspect} not pulled at #{base} -- run `ollama pull #{model}` " \
      "(server has: #{names.empty? ? "none" : names.join(", ")})"
  end

  # A short-timeout GET /api/tags. Any connection/parse failure means "treat as
  # unreachable" -- the caller turns that into a skip, so a torn probe never
  # masquerades as a test failure.
  def self.fetch_tags(base)
    uri = URI.join(base, "/api/tags")
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = 2
    http.read_timeout = 5
    response = http.get(uri.request_uri)
    return nil unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue SystemCallError, SocketError, Timeout::Error, JSON::ParserError, IOError
    nil
  end
end

# What is ollama's own about a cassette-backed example: whether it probes for a
# server first. The PERMISSION question is not ollama's -- :api_integration and
# :live had the identical silent-cassette-drop bug, so it lives in one place, in
# ExampleNetwork (spec/support/tags.rb), and this file is one of its callers.
module OllamaTagPosture
  # A cassette-backed example does not probe for a server. Replaying one needs
  # none, so a probe would skip a perfectly good offline example; recording one
  # does need a server, and a dead server must then fail LOUDLY -- a skipped
  # recording writes no cassette and is indistinguishable from a successful one.
  #
  # The probe could not run here in any case: it is a real `GET /api/tags`, and
  # by the time a `before` hook runs the cassette is already inserted, so the
  # request would either be recorded into the cassette or raise against it.
  def self.unreachable_reason(metadata)
    OllamaTestServer.unreachable_reason unless ExampleNetwork.cassette_backed?(metadata)
  end
end

RSpec.configure do |config|
  # :ollama examples reach localhost for their duration only, then isolation is
  # restored even on raise -- the same permission the :api_integration and :live
  # tags take, through the same object, which is also what makes a cassette-backed
  # :ollama example keep its cassette. See ExampleNetwork for what that cost.
  config.around(:each, :ollama) do |example|
    ExampleNetwork.permit(example.metadata) { example.run }
  end

  # Skip-not-fail when the server is down or the model is absent (see above).
  config.before(:each, :ollama) do |example|
    reason = OllamaTagPosture.unreachable_reason(example.metadata)
    skip(reason) if reason
  end

  unless OLLAMA_ENABLED
    config.filter_run_excluding(:ollama)

    config.before(:suite) do
      RSpec.configuration.reporter.message(
        "Skipping :ollama specs. Set LAIN_OLLAMA=1 (with `ollama serve` + " \
        "`ollama pull #{OllamaTestServer::MODEL}`) to run them."
      )
    end
  end
end

# The offline-default guards for this tag are untagged real specs in
# spec/network_posture_spec.rb -- see its header for why they are neither
# here nor tagged :ollama.
