# frozen_string_literal: true

require "net/http"

# The offline-by-default posture, PROVEN in the default suite -- these guards
# were asked for by the coordinator and are untagged on purpose: a regression
# spec tagged :integration/:ollama would be excluded by default and catch
# nothing, which is exactly how the permit bug slipped in the first time.
#
# They live HERE, not next to the configuration they guard in spec/support/,
# because support files load in every worker process: a describe block defined
# there runs once PER WORKER under parallel_rspec, once per suite here. The
# switches themselves (NetworkAccess, the tag gating, the VCR hook) stay in
# spec/support -- this file only holds the proof.

RSpec.describe NetworkAccess do
  describe ".permit" do
    # Uses 127.0.0.1:1 (a port nothing listens on) so the request reaches the
    # socket and is refused locally; no traffic ever leaves the machine.
    it "reaches the socket inside the block" do
      expect { NetworkAccess.permit { Net::HTTP.get(URI("http://127.0.0.1:1/")) } }
        .to raise_error(Errno::ECONNREFUSED)
    end

    it "restores the offline default after the block, even for a request with no cassette" do
      NetworkAccess.permit { nil }
      expect { Net::HTTP.get(URI("http://127.0.0.1:1/")) }
        .to raise_error(VCR::Errors::UnhandledHTTPRequestError)
    end
  end
end

# Once `hook_into :webmock` has run, VCR -- not WebMock -- decides whether an
# unstubbed request goes out, for EVERY example, not just ones tagged :vcr.
# The authoritative gate is VCR's `allow_http_connections_when_no_cassette?`
# and the raise is VCR's own error, not WebMock's NetConnectNotAllowedError.
# Both facts are pinned here; they are why opting back INTO the network takes
# NetworkAccess.permit rather than a bare WebMock.allow_net_connect!.
RSpec.describe "network isolation" do
  it "blocks HTTP connections when no cassette is inserted" do
    expect(VCR.configuration.allow_http_connections_when_no_cassette?).to be(false)
  end

  it "raises rather than silently reaching out, for a request with no stub or cassette" do
    expect { Net::HTTP.get(URI("https://api.anthropic.com/v1/messages")) }
      .to raise_error(VCR::Errors::UnhandledHTTPRequestError)
  end
end

RSpec.describe "the :ollama tag's offline default" do
  it "excludes :ollama examples unless LAIN_OLLAMA=1" do
    skip "LAIN_OLLAMA=1 opts :ollama examples in" if OLLAMA_ENABLED

    expect(RSpec.configuration.exclusion_filter[:ollama]).to be(true)
  end

  it "blocks a localhost Ollama call from any untagged example" do
    # No :ollama tag here, so NetworkAccess.permit never runs and VCR (the layer
    # that owns the switch once hooked into WebMock) refuses the request -- the
    # request never leaves the machine, whether or not a server is listening.
    expect { Net::HTTP.get(URI.join(OLLAMA_API_BASE, "/api/tags")) }
      .to raise_error(VCR::Errors::UnhandledHTTPRequestError)
  end
end
