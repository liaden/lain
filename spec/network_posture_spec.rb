# frozen_string_literal: true

require "net/http"
require "socket"

# The offline-by-default posture, PROVEN in the default suite -- these guards
# were asked for by the coordinator and are untagged on purpose: a regression
# spec tagged :api_integration/:ollama would be excluded by default and catch
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
      expect { described_class.permit { Net::HTTP.get(URI("http://127.0.0.1:1/")) } }
        .to raise_error(Errno::ECONNREFUSED)
    end

    it "restores the offline default after the block, even for a request with no cassette" do
      described_class.permit { nil }
      expect { Net::HTTP.get(URI("http://127.0.0.1:1/")) }
        .to raise_error(VCR::Errors::UnhandledHTTPRequestError)
    end
  end

  # The narrow allowance. `.permit` above opens the WHOLE network and turns VCR
  # off for its block; this opens exactly one loopback port and leaves VCR on,
  # which is what a fake upstream (reachable, no cassette) and a real recording
  # (cassette inserted, must still record) each need.
  describe ".permit_loopback" do
    # Enough server to prove a socket opened: one ephemeral port and a canned
    # response, torn down in an ensure. The severable instrument the retry specs
    # need is a separate, larger thing -- this file only proves the door opens
    # for one port and stays shut for everything else.
    # Yields the bound port and a live list of the request lines the server has
    # actually served -- "did a socket open" is the only thing several of these
    # examples can honestly assert, and a refusal that raises for the wrong
    # reason would still leave the list empty.
    def with_loopback_server(body)
      server = TCPServer.new("127.0.0.1", 0)
      hits = []
      thread = Thread.new { serve(server, body, hits) }
      begin
        yield server.addr[1], hits
      ensure
        thread.kill
        server.close
      end
    end

    def serve(server, body, hits)
      Thread.current.report_on_exception = false
      Kernel.loop do
        session = server.accept
        request = session.each_line.take_while { |line| line != "\r\n" }.to_a
        hits << request.first.to_s.strip
        session.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
        session.close
      end
    end

    # A cassette written here would land in spec/fixtures/vcr_cassettes and be
    # committed by accident, so the library dir moves for the block.
    def in_a_temp_cassette_library
      original = VCR.configuration.cassette_library_dir
      Dir.mktmpdir("lain-posture") do |dir|
        VCR.configuration.cassette_library_dir = dir
        begin
          yield dir
        ensure
          VCR.configuration.cassette_library_dir = original
        end
      end
    end

    it "reaches a server listening on the permitted port" do
      with_loopback_server("permitted") do |port|
        response = described_class.permit_loopback(port) { Net::HTTP.get(URI("http://127.0.0.1:#{port}/")) }

        expect(response).to eq("permitted")
      end
    end

    # The two halves of the matcher, one example each, and each on the SAME axis
    # the implementation could get wrong. A refusal that differs from the
    # permitted destination in host AND port proves nothing: it holds equally for
    # a port-only allowance, which would open evil.example.com:11434 the moment
    # T3 holds Ollama's port. The addresses below are RFC 5737 TEST-NET-1 and
    # RFC 3849 documentation space -- unroutable, so a regression that let one
    # through still cannot reach anybody.
    it "refuses a NON-LOOPBACK host on the very port that is held" do
      with_loopback_server("permitted") do |port, hits|
        described_class.permit_loopback(port) do
          expect { Net::HTTP.get(URI("http://192.0.2.1:#{port}/")) }
            .to raise_error(VCR::Errors::UnhandledHTTPRequestError)
          expect { Net::HTTP.get(URI("http://[2001:db8::1]:#{port}/")) }
            .to raise_error(VCR::Errors::UnhandledHTTPRequestError)
          expect { Net::HTTP.get(URI("http://api.anthropic.com:#{port}/v1/messages")) }
            .to raise_error(VCR::Errors::UnhandledHTTPRequestError)
        end

        expect(hits).to be_empty
      end
    end

    it "refuses a LOOPBACK host on a port that is not held" do
      with_loopback_server("permitted") do |port, hits|
        described_class.permit_loopback(port) do
          expect { Net::HTTP.get(URI("http://127.0.0.1:1/")) }
            .to raise_error(VCR::Errors::UnhandledHTTPRequestError)
        end

        expect(hits).to be_empty
      end
    end

    it "refuses the same port again once the permission is released" do
      with_loopback_server("permitted") do |port|
        described_class.permit_loopback(port) { Net::HTTP.get(URI("http://127.0.0.1:#{port}/")) }

        expect { Net::HTTP.get(URI("http://127.0.0.1:#{port}/")) }
          .to raise_error(VCR::Errors::UnhandledHTTPRequestError)
      end
    end

    # An `around` hook that permits a port can wrap an example that permits the
    # same one, so a release is a decrement rather than a revocation.
    it "keeps an outer permission alive when a nested one for the same port is released" do
      with_loopback_server("permitted") do |port|
        described_class.permit_loopback(port) do
          described_class.permit_loopback(port) { Net::HTTP.get(URI("http://127.0.0.1:#{port}/")) }

          expect(Net::HTTP.get(URI("http://127.0.0.1:#{port}/"))).to eq("permitted")
        end
      end
    end

    it "restores the posture even when the block raises" do
      with_loopback_server("permitted") do |port|
        expect { described_class.permit_loopback(port) { raise "boom" } }.to raise_error("boom")
        expect { Net::HTTP.get(URI("http://127.0.0.1:#{port}/")) }
          .to raise_error(VCR::Errors::UnhandledHTTPRequestError)
      end
    end

    # The two escalation triggers this card was given, asserted rather than
    # asserted-in-prose: the narrow allowance must not reach for
    # `WebMock.allow_net_connect!`, and it must not turn VCR off.
    it "neither turns VCR off nor touches the blunt WebMock switch" do
      with_loopback_server("permitted") do |port|
        described_class.permit_loopback(port) do
          expect(VCR.turned_on?).to be(true)
          expect(WebMock::Config.instance.allow_net_connect).to be_falsey
        end
      end
    end

    it "refuses to hold anything that is not a port" do
      expect { described_class.permit_loopback("11434") { nil } }
        .to raise_error(ArgumentError, /integer/)
    end

    # An inserted cassette WINS over the permission, and this is the example that
    # pins it: the obvious implementation adds the destination to VCR's ignore
    # list, and VCR refuses to record a request it ignored (vcr.rb:390-395), so
    # that version reaches the server and writes an EMPTY cassette.
    #
    # READ BEFORE ADDING A REQUEST TO THIS BLOCK. A recording-mode cassette is a
    # network window belonging to the CASSETTE, not to the permission: inside one
    # `VCR.real_http_connections_allowed?` is true for EVERY host, and
    # `permit_loopback` does not narrow it (a request to a remote address in here
    # opens a real socket and blocks until the watchdog kills the example). The
    # window is contained by construction -- exactly one loopback request -- and
    # the assertions below are what say so. `vcr_configuration.rb` states the
    # policy this is the exception to: recording is an explicit act, never a side
    # effect of running the suite.
    it "records to an inserted cassette rather than bypassing it" do
      with_loopback_server(%({"ok":true})) do |port, hits|
        in_a_temp_cassette_library do |dir|
          VCR.use_cassette("loopback_recording", record: :all) do
            expect(VCR.real_http_connections_allowed?).to be(true) # the CASSETTE's doing, not the permission's
            described_class.permit_loopback(port) do
              expect(Net::HTTP.get(URI("http://127.0.0.1:#{port}/api/chat"))).to eq(%({"ok":true}))
            end
          end

          expect(VCR.real_http_connections_allowed?).to be(false) # the window closed with the cassette
          expect(hits).to eq(["GET /api/chat HTTP/1.1"]) # and held exactly one request while open
          expect(File.read(File.join(dir, "loopback_recording.yml")))
            .to include("/api/chat", %({"ok":true}))
        end
      end
    end

    # The other side of "the cassette wins", and the one that will bite: at the
    # suite's DEFAULT record mode a cassette does not open a window, it CLOSES
    # the permission. An example that merely carries the :vcr tag gets a cassette
    # for its whole body (`configure_rspec_metadata!`), so a seam spec that
    # acquires that tag -- or lands inside an outer cassette -- finds
    # `permit_loopback` silently inert. The error names neither the permission
    # nor the cassette, so this example is where a reader learns the cause.
    it "is defeated, not merely ignored, by a cassette that is replaying" do
      with_loopback_server(%({"ok":true})) do |port, hits|
        in_a_temp_cassette_library do
          VCR.use_cassette("loopback_replay_only") do # the suite default: record: :none
            expect { described_class.permit_loopback(port) { Net::HTTP.get(URI("http://127.0.0.1:#{port}/api/chat")) } }
              .to raise_error(VCR::Errors::UnhandledHTTPRequestError)
          end
        end

        expect(hits).to be_empty
      end
    end

    it "refuses to run without a block, naming itself rather than raising LocalJumpError" do
      expect { described_class.permit_loopback(11_434) }
        .to raise_error(ArgumentError, /permit_loopback/)
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
