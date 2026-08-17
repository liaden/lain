# frozen_string_literal: true

# `Provider::Ollama#context_window_tokens` GETs `/api/ps` to learn the window the
# server is actually serving, and `CLI::Backend` now asks for that at LAUNCH --
# so any example that builds an ollama-backed Backend makes the request, whether
# or not it cares about windows. Without a stub the probe reaches VCR's gate,
# which raises `VCR::Errors::UnhandledHTTPRequestError`: not a `Faraday::Error`,
# so `#context_window_tokens`' own rescue cannot see it, and it surfaces far from
# the example that caused it. Eight files broke that way the first time the book
# was wired, and the next spec to build a Backend would have broken the same way.
#
# The default answers "nothing resident", which is chosen precisely because it
# CHANGES NO MEASUREMENT: an empty `models` array means the provider reports no
# served window, so `ContextWindow`'s own fallback stays in charge and every
# example measures exactly what it measured before the book existed. A default
# naming a window would silently re-denominate occupancy across the suite.
#
# WebMock matches the most recently registered stub first, so a file or example
# that wants a resident runner simply registers its own and wins -- which is what
# the specs that DO care about windows already rely on. The one shape that needs
# care is an example asserting the probe was never made: it must reset WebMock
# rather than assume a clean slate, because this registration is already there.
#
# A CASSETTE is the exception, and it is not covered by "register your own and
# win" -- it is the reverse. VCR hooks into WebMock as a GLOBAL stub
# (`WebMock::StubRegistry#register_global_stub`) and WebMock consults locally
# registered stubs FIRST, so this `before` beats every cassette rather than
# losing to it. Measured, not read off the docs: with both in place a cassette
# recording `context_length: 8192` was answered `{"models":[]}`, and a recorded
# `/api/ps` was unreachable by construction. That was the plan's blocker #2.
#
# So the registration YIELDS when the VCR context in force can answer the probe
# itself, and covers everything else exactly as before. Both halves matter: the
# empty body was chosen because it CHANGES NO MEASUREMENT, and skipping it for
# an example whose cassette has no `/api/ps` would re-break the eight files this
# stub exists for.
#
# The question is VCR's, not ollama's -- nesting, playback consumption and
# recorded-host differences all bear on it -- so it is asked of
# {VcrCassetteStack} in spec/support/vcr_configuration.rb. This file supplies
# only the endpoint and the default answer.
#
# One consequence worth stating for whoever records a multi-turn cassette: once
# a cassette owns `/api/ps`, it owns it for good, so a SECOND probe against a
# cassette holding one recorded `/api/ps` RAISES rather than quietly falling
# back to the empty body. `Provider::Ollama#context_window_tokens` is probed
# once per turn, so an N-turn cassette wants N recorded probes. That loudness is
# deliberate: the silent version hands compaction accounting a nil that looks
# exactly like "no runner resident".
module OllamaProbeStub
  PATH = "/api/ps"

  def self.cassette_answers?
    VcrCassetteStack.serves?(PATH)
  end
end

RSpec.configure do |config|
  # The yielding is a MATCH-TIME predicate, not a registration-time one, and it
  # has to be. VCR 6.4.0 inserts a cassette from `config.before(:each, :vcr)` --
  # a before hook, NOT an around (`vcr/test_frameworks/rspec.rb:36`) -- so hooks
  # run in registration order, and support files load in `Dir[]` order, which
  # puts this file ahead of vcr_configuration.rb. At registration time there is
  # no cassette to ask about yet. Fixing that by reordering the glob is exactly
  # what spec_helper.rb:16-19 says not to do.
  #
  # WebMock evaluates a `with` block when the REQUEST is made, by which point
  # the cassette is inserted; returning false there makes this stub simply not
  # match, and the request falls through to VCR's global stub -- the cassette.
  config.before do
    stub_request(:get, %r{/api/ps})
      .with { !OllamaProbeStub.cassette_answers? }
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: '{"models":[]}')
  end
end
