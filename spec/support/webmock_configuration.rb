# frozen_string_literal: true

require "net/http"

# `webmock/rspec` (required from spec_helper.rb, before this glob runs) already
# disables real network connections for every example and resets stubs between
# examples. There is nothing further to configure -- WebMock is the layer VCR
# hooks into (see vcr_configuration.rb), not a place we register our own global
# stubs. What we own instead is PROVING that posture holds: "a spec with no
# cassette and no :integration/:live tag cannot reach the network" is an
# acceptance criterion for this branch, not just an assumption about a gem's
# defaults.
#
# Verified, not assumed: once `VCR.configure { |c| c.hook_into :webmock }` has
# run (vcr_configuration.rb sorts before this file, so it always has by the
# time an example executes), VCR becomes the layer that actually decides
# whether an unstubbed request goes through -- for EVERY example in the suite,
# not just ones tagged :vcr. The authoritative gate is therefore VCR's
# `allow_http_connections_when_no_cassette?`, set false in
# vcr_configuration.rb, and an unmatched request raises
# VCR::Errors::UnhandledHTTPRequestError -- not WebMock's own
# NetConnectNotAllowedError. Both facts are pinned by the examples below. That
# VCR now owns the switch is why opting back INTO the network takes
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
