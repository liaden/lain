# frozen_string_literal: true

require "net/http"

# The one true way through the offline default, for :integration and :live.
#
# `WebMock.allow_net_connect!` is NOT sufficient once VCR has hooked into
# WebMock (see vcr_configuration.rb): from that point VCR -- not WebMock --
# decides whether an unstubbed request goes out, and its
# `allow_http_connections_when_no_cassette` is false. So flipping only the
# WebMock switch leaves the door shut, and a spec that "opts into the network"
# raises `VCR::Errors::UnhandledHTTPRequestError` instead of reaching the API.
# Both switches have to move together, and they have to move back together.
#
# Extracted into a named collaborator for one reason: it makes the capability
# PROVABLE in the default suite. The describe block below runs untagged, so if
# someone re-breaks the path -- e.g. drops the `VCR.turned_off` and trusts
# `allow_net_connect!` alone -- the default `rspec` run goes red. A regression
# spec tagged :integration would be excluded by default and catch nothing,
# which is exactly how this bug slipped in the first time.
module NetworkAccess
  # Run the block with real network access, then restore isolation no matter
  # what the block does.
  def self.permit(&block)
    WebMock.allow_net_connect!
    VCR.turned_off(ignore_cassettes: true, &block)
  ensure
    WebMock.disable_net_connect!
  end
end

# Untagged ON PURPOSE -- this is the guard the coordinator asked for. Uses
# 127.0.0.1:1 (a port nothing listens on) so the request reaches the socket
# and is refused locally; no traffic ever leaves the machine.
RSpec.describe NetworkAccess do
  describe ".permit" do
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
