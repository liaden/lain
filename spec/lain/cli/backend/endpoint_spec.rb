# frozen_string_literal: true

# `--api-base "localhost:11434"` is a VALID URI -- scheme `localhost`, opaque
# `11434`, no host -- so `URI.parse` never raises for the ordinary way an
# operator leaves the scheme off. The question this validates is not "does
# `URI.parse` succeed" but "is there an http/https scheme and a host to send
# a request to". See {Lain::CLI::Backend#initialize}'s eager-refusal list for
# where this is actually reached: this file is {Endpoint} on its own.
RSpec.describe Lain::CLI::Backend::Endpoint do
  def endpoint(value) = described_class.new(flag: "--api-base", value:)

  # The headline defect: a scheme-less base parses as a URI with no host, and
  # that -- not a parse failure -- is what must be refused.
  it "refuses a scheme-less base, naming the flag and the value" do
    expect { endpoint("localhost:11434").url }
      .to raise_error(Lain::CLI::Backend::InvalidEndpoint, /--api-base "localhost:11434"/)
  end

  it "says a scheme is required for a scheme-less base" do
    expect { endpoint("localhost:11434").url }
      .to raise_error(Lain::CLI::Backend::InvalidEndpoint, /scheme is required/)
  end

  # Not every bad value is even a URI -- this one fails to parse at all, and
  # must still come back as the named refusal, not a raw URI::InvalidURIError.
  it "refuses a value that is not a URI at all, naming the flag rather than a URI parse error" do
    expect { endpoint("not a url").url }
      .to raise_error(Lain::CLI::Backend::InvalidEndpoint, /--api-base "not a url"/)
  end

  it "refuses a non-http scheme" do
    expect { endpoint("ftp://example.com").url }
      .to raise_error(Lain::CLI::Backend::InvalidEndpoint, %r{--api-base "ftp://example.com"})
  end

  # `URI.parse("http://").host` is `""`, not `nil` -- a naive `uri.host.nil?`
  # check misses this and lets an empty host straight through to Faraday,
  # which is the exact failure class this whole card exists to refuse, just
  # spelled differently from the `localhost:11434` typo above.
  it "refuses an empty host the same way as a missing one" do
    expect { endpoint("http://").url }
      .to raise_error(Lain::CLI::Backend::InvalidEndpoint, /scheme is required/)
  end

  # The reachable real-world trigger: `--api-base "http://$OLLAMA_HOST"` with
  # `OLLAMA_HOST` unset interpolates to exactly this -- an ordinary
  # misconfiguration, not a hand-typed flag.
  it "refuses an empty host with a path, as an unset $OLLAMA_HOST would interpolate" do
    expect { endpoint("http:///x").url }
      .to raise_error(Lain::CLI::Backend::InvalidEndpoint, /scheme is required/)
  end

  # The ordinary case: a well-formed http(s) base is accepted VERBATIM --
  # validation checks shape, it does not normalize.
  it "accepts an ordinary http base unchanged" do
    expect(endpoint("http://localhost:11434").url).to eq("http://localhost:11434")
  end

  it "accepts an ordinary https base unchanged" do
    expect(endpoint("https://ollama.example.com").url).to eq("https://ollama.example.com")
  end

  it "is a Lain::Error, so the exe presents it cleanly rather than as a backtrace" do
    expect(Lain::CLI::Backend::InvalidEndpoint).to be < Lain::Error
  end
end
