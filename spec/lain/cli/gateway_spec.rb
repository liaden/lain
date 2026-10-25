# frozen_string_literal: true

require "digest"
require "json"
require "socket"
require "tmpdir"

# Defines LainCLI without starting it, the seam spec/lain/cli_spec.rb uses.
load File.expand_path("../../../exe/lain", __dir__)

RSpec.describe Lain::CLI::Gateway do
  let(:dir) { Dir.mktmpdir("cli-gateway") }
  let(:log) { File.join(dir, "gateway.ndjson") }
  let(:paths) { Lain::Paths.new(env: { "HOME" => dir, "XDG_STATE_HOME" => File.join(dir, "state") }) }
  let(:console) { recording_console }
  let(:options) { { "upstream" => "https://ollama.com", "port" => 0, "root" => dir, "log" => log } }

  def recording_console
    Class.new do
      attr_reader :announced, :asked

      def initialize
        @announced = Thread::Queue.new
        @asked = []
      end

      def announce(url:, log:, caveats: []) = @announced << { url:, log:, caveats: }

      def approve?(request)
        @asked << request
        false
      end
    end.new
  end

  def gateway(given = options, env: { "OLLAMA_API_KEY" => "gateway-key" })
    described_class.new(given, console:, env:, paths:)
  end

  # Serves on its own thread, as `exe/lain gateway` serves on the main one,
  # and is interrupted the way Ctrl-C interrupts it.
  def serving(cli = gateway)
    thread = Thread.new { cli.run }.tap { _1.report_on_exception = false }
    announced = console.announced.pop(timeout: 5) or raise "the gateway never announced"
    yield announced
  ensure
    thread.raise(Interrupt)
    expect { thread.join(5) }.to raise_error(Interrupt)
  end

  def exchange(port, request)
    TCPSocket.open("127.0.0.1", port) do |socket|
      socket.timeout = 5
      socket.write(request)
      socket.read
    end
  end

  def port_of(url) = URI(url).port

  def post(url, body)
    exchange(port_of(url), "POST /api/chat HTTP/1.1\r\nHost: 127.0.0.1:#{port_of(url)}\r\n" \
                           "Content-Length: #{body.bytesize}\r\n\r\n#{body}")
  end

  def asking(content) = JSON.generate({ model: "m", stream: false, messages: [{ role: "user", content: }] })

  around { |example| with_env("OLLAMA_API_KEY" => "gateway-key") { example.run } }

  after { FileUtils.rm_rf(dir) }

  it "listens on 127.0.0.1 and announces its URL with a one-time token and its log" do
    serving do |announced|
      expect(announced[:url]).to match(%r{\Ahttp://127\.0\.0\.1:\d+/\?token=\h{32}\z})
      expect(announced[:log]).to eq(log)
      token = announced[:url][/token=(\h+)/, 1]
      port = port_of(announced[:url])
      reply = exchange(port, "GET #{Lain::Gateway::IDENTITY_PATH}?token=#{token} HTTP/1.1\r\n" \
                             "Host: 127.0.0.1:#{port}\r\n\r\n")

      expect(reply).to include(JSON.generate({ digest: Digest::SHA256.hexdigest(token) }))
    end
  end

  it "offers no bind option" do
    expect { LainCLI.start(%w[gateway --upstream https://ollama.com --bind 0.0.0.0], debug: true) }
      .to raise_error(Thor::UnknownArgumentError, /--bind/)
  end

  it "mints a fresh token on every start" do
    tokens = Array.new(2) { serving { |announced| announced[:url][/token=(\h+)/, 1] } }

    expect(tokens.uniq.size).to eq(2)
  end

  [99_999, -1, 1.5, "80"].each do |port|
    it "refuses a port of #{port.inspect} before it listens" do
      expect { gateway(options.merge("port" => port)).run }.to raise_error(Lain::Error, /port/)
      expect(console.announced).to be_empty
    end
  end

  it "warns at start that a root outside git leaves only the environment's secrets checked" do
    serving do |announced|
      expect(announced[:caveats]).to contain_exactly(a_string_including("not a git checkout", "environment"))
    end
  end

  context "with a git checkout for its root" do
    let(:repo) { File.join(dir, "repo") }
    let(:options) { super().merge("root" => repo) }

    before do
      FileUtils.mkdir_p(repo)
      FileUtils.cp_r("#{SeedRepo.at({ ".gitignore" => ".env\n" })}/.", repo)
      File.write(File.join(repo, ".env"), "TOKEN=at-start-secret-abcdef0123456789\n")
    end

    it "announces no caveat" do
      serving { |announced| expect(announced[:caveats]).to be_empty }
    end

    it "reads the secrets again for each request, so one written after start is refused" do
      serving do |announced|
        File.write(File.join(repo, ".env"), "TOKEN=after-start-secret-abcdef0123456789\n")

        expect(post(announced[:url], asking("after-start-secret-abcdef0123456789"))).to start_with("HTTP/1.1 403")
        expect(console.asked).to be_empty
      end
    end
  end

  it "stops listening once interrupted" do
    port = nil
    serving { |announced| port = port_of(announced[:url]) }

    expect { TCPSocket.new("127.0.0.1", port).close }.to raise_error(Errno::ECONNREFUSED)
  end

  it "refuses an upstream outside the allow-list before it listens" do
    expect { gateway(options.merge("upstream" => "https://example.com")).run }
      .to raise_error(Lain::Gateway::Upstream::NotAllowed)
    expect(console.announced).to be_empty
  end

  it "refuses to start without the upstream's key in its environment" do
    expect { gateway(env: {}).run }.to raise_error(Lain::Gateway::Upstream::MissingKey, /OLLAMA_API_KEY/)
  end

  it "refuses a body carrying a secret from its own environment without asking the human" do
    secret = "gateway-env-secret-0123456789"
    cli = gateway(env: { "OLLAMA_API_KEY" => "gateway-key", "API_SECRET" => secret })
    body = JSON.generate({ model: "m", stream: false, messages: [{ role: "user", content: secret }] })

    serving(cli) do |announced|
      expect(post(announced[:url], body)).to start_with("HTTP/1.1 403")
      expect(console.asked).to be_empty
    end
  end

  it "logs under the state home when no log is named" do
    serving(gateway(options.except("log"))) do |announced|
      expect(announced[:log]).to start_with(File.join(paths.state_home, "gateway"))
    end
  end
end
