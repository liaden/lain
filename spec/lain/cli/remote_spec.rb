# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe Lain::CLI::Remote do
  let(:dir) { Dir.mktmpdir("remote") }
  let(:paths) { Lain::Paths.new(env: { "HOME" => dir, "XDG_STATE_HOME" => File.join(dir, "state") }) }
  let(:devices) { Lain::Remote::Devices.for(paths:) }
  let(:sink) { StringIO.new }
  let(:tailnet) { [Addrinfo.ip("100.101.2.3")] }

  after { FileUtils.rm_rf(dir) }

  def remote(verb, name = nil, addresses: tailnet)
    described_class.new(verb:, name:, sink:, paths:, tailnet: -> { addresses })
  end

  describe "pair" do
    it "prints the new token once with the relay address for the app's settings" do
      status = remote("pair", "pixel").run
      token = sink.string[/^token: (\S+)$/, 1]

      expect([status, sink.string.scan(token).size]).to eq([0, 1])
      expect(sink.string).to include("relay: 100.101.2.3:#{described_class::RELAY_PORT}")
      expect(File.read(devices.path)).to eq("pixel #{Lain::Ext.blake3_hex(token)}\n")
    end

    it "says so when this host has no tailnet address to give the app" do
      remote("pair", "pixel", addresses: []).run

      expect(sink.string).to include("relay: none, this host has no tailscale0 address")
    end

    it "needs a device name" do
      expect { remote("pair").run }.to raise_error(Lain::Error, "lain remote pair needs a device name")
    end

    it "refuses a name already paired, as a Lain::Error the CLI reports" do
      remote("pair", "pixel").run

      expect { remote("pair", "pixel").run }.to raise_error(Lain::Error, "pixel is already paired; revoke it first")
    end
  end

  describe "revoke" do
    it "drops the device from the devices file the relay rereads" do
      remote("pair", "pixel").run
      remote("pair", "tablet").run
      status = remote("revoke", "pixel").run

      expect([status, File.read(devices.path).lines.map { _1.split.first }]).to eq([0, ["tablet"]])
      expect(sink.string.lines.last).to eq("revoked pixel; the relay closes its connection when it rereads the file\n")
    end

    it "refuses a device that is not paired" do
      expect { remote("revoke", "pixel").run }.to raise_error(Lain::Error, "pixel is not paired")
    end
  end

  it "names the verbs it knows when given another" do
    expect { remote("list").run }.to raise_error(Lain::Error, 'lain remote knows pair and revoke, not "list"')
  end

  it "finds this host's tailscale0 addresses by default" do
    interfaces = { "eth0" => "192.168.1.5", "tailscale0" => "100.64.7.8" }.map do |name, ip|
      instance_double(Socket::Ifaddr, name:, addr: Addrinfo.ip(ip))
    end
    allow(Socket).to receive(:getifaddrs).and_return(interfaces)
    described_class.new(verb: "pair", name: "pixel", sink:, paths:).run

    expect(sink.string).to include("relay: 100.64.7.8:#{described_class::RELAY_PORT}")
  end
end
