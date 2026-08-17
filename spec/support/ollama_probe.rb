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
RSpec.configure do |config|
  config.before do
    stub_request(:get, %r{/api/ps}).to_return(
      status: 200, headers: { "Content-Type" => "application/json" }, body: '{"models":[]}'
    )
  end
end
