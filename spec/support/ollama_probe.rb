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
#
# A SECOND endpoint was added on the same launch path, for the same reason and
# with the same default. `CLI::Backend#num_ctx` asks `/api/show` for the model's
# TRAINED maximum, to refuse a `--num-ctx` no runner could ever serve -- but only
# when the flag is actually set, and only when a reader forces it, so most
# examples never reach it. The
# default answers a body with no `model_info`, which means "no ceiling
# discoverable": a provider that cannot state one must not block a launch, so
# again nothing an example measures moves.
#
# HOST-SCOPED, not just path-matched -- found while wiring the Cloud arm. The
# path-only regex above answered these two probes for ANY host, so a provider
# wrongly built against a hosted deployment (Ollama Cloud, or any future
# non-local one) that called `/api/ps` or `/api/show` would get a quiet
# `{"models":[]}`/`{}` back instead of reaching VCR's gate -- indistinguishable
# from a normal local probe of an empty server. That silence is exactly what
# this file's own header says the OTHER path-matching failure mode (an
# unstubbed local probe) must never do. "Local" is not the literal string
# `localhost:11434`: `OLLAMA_API_BASE` is a spec-level knob a developer points at
# a non-default local server (spec/support/ollama_tag.rb), and the stub must
# still answer THAT host too, or their `:ollama` run breaks.
#
# "Local" is answered by folding through {Provider::Admission::Endpoint.canonical}
# -- the repo's ONE existing answer to "which server does this endpoint name" --
# rather than by a second, narrower definition invented here. A `[host, port]`
# equality check against two literal strings disagreed with both
# `spec/support/network_access.rb`'s `LOOPBACK_HOSTS` and `Endpoint.canonical`
# itself: the identical server spelled `127.0.0.1` or `::1` failed to match
# `localhost`, so the SAME `--api-base http://127.0.0.1:11434` that Admission
# already treats as one server with `localhost:11434` (`admission_spec.rb:290`)
# would have gotten no stub and reached VCR's gate instead. Found in review, not
# by the suite -- see `probes/t9_loopback_alias_spec.rb` for the reproduction on
# the real launch path.
module OllamaProbeStub
  PATH = "/api/ps"
  SHOW_PATH = "/api/show"

  def self.cassette_answers?(path = PATH)
    VcrCassetteStack.serves?(path)
  end

  # The two bases a genuine local probe can land on: the library's own default
  # (a provider built with no `api_base:` at all -- most of the suite) and the
  # spec-level override (a provider a developer or an :ollama example pointed
  # explicitly at OLLAMA_API_BASE). Not memoized: two constant lookups and an
  # array literal cost nothing, and there is no correctness reason to cache them
  # -- OLLAMA_API_BASE is itself a constant, fixed once at load, not something
  # that changes mid-run.
  def self.local_bases
    [::Lain::Provider::Ollama::Transport::DEFAULT_API_BASE, OLLAMA_API_BASE]
  end

  # Same SERVER, not same spelling. Delegates the "which host" question
  # entirely to {Provider::Admission::Endpoint.canonical}, which already folds
  # every loopback spelling (`127.0.0.1`, `::1`, `localhost`, a trailing-dot
  # FQDN) to one name and never raises on a malformed endpoint -- so this
  # inherits that safety rather than re-deriving it. `server_key` then drops the
  # scheme from canonical's result: these stubs exist to keep the suite's own
  # local traffic quiet and have no opinion on http vs. https, so two spellings
  # that differ only in scheme must still match.
  def self.local?(uri)
    candidate = server_key(uri.to_s)
    local_bases.any? { |base| server_key(base) == candidate }
  end

  def self.server_key(uri_string)
    ::Lain::Provider::Admission::Endpoint.canonical(uri_string).split("://", 2).last.split("/", 2).first
  end
  private_class_method :server_key
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
  # match, and the request falls through to VCR's global stub -- a cassette for
  # a local recording, or (now) an ordinary refusal for a non-local host.
  config.before do
    stub_request(:get, %r{/api/ps})
      .with { |request| OllamaProbeStub.local?(request.uri) && !OllamaProbeStub.cassette_answers? }
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: '{"models":[]}')
    stub_request(:post, %r{/api/show})
      .with do |request|
        OllamaProbeStub.local?(request.uri) && !OllamaProbeStub.cassette_answers?(OllamaProbeStub::SHOW_PATH)
      end
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: "{}")
  end
end
