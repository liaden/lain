# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Remote::Devices do
  let(:dir) { Dir.mktmpdir("devices") }
  let(:paths) { Lain::Paths.new(env: { "HOME" => dir, "XDG_STATE_HOME" => File.join(dir, "state") }) }
  let(:devices) { described_class.for(paths:) }

  after { FileUtils.rm_rf(dir) }

  def mode(path) = File.lstat(path).mode & 0o777

  def paired_names = File.read(devices.path).lines.map { _1.split.first }

  def refusal
    yield
    nil
  rescue described_class::Refused => e
    e.message
  end

  it "lives alone in a remote directory under the state home" do
    expect(devices.path).to eq(File.join(dir, "state", "lain", "remote", "devices"))
  end

  describe "#pair" do
    it "writes a 0600 file in a 0700 directory, one line of name and token digest per device" do
      token = devices.pair("pixel")

      expect([mode(devices.path), mode(File.dirname(devices.path))]).to eq([0o600, 0o700])
      expect(File.read(devices.path)).to eq("pixel #{Lain::Ext.blake3_hex(token)}\n")
    end

    it "stores a hash of each token and never the token" do
      token = devices.pair("pixel")

      expect(File.read(devices.path)).not_to include(token)
    end

    it "makes a new random token for each device" do
      tokens = [devices.pair("pixel"), devices.pair("tablet")]

      expect([tokens.uniq.size, tokens.map(&:size).min]).to eq([2, 43])
    end

    it "keeps the devices already paired" do
      devices.pair("pixel")
      devices.pair("tablet")

      expect(paired_names).to eq(%w[pixel tablet])
    end

    it "refuses a name already paired, so a pair never replaces a token in silence" do
      devices.pair("pixel")

      expect(refusal { devices.pair("pixel") }).to eq("pixel is already paired; revoke it first")
    end

    it "refuses a name the relay's file could not hold" do
      ["", "two words", "a" * 33, "-dash", "line\nbreak"].each do |name|
        expect(refusal { devices.pair(name) }).to include("is not a device name")
      end
    end

    it "refuses a devices directory that is a symlink" do
      FileUtils.mkdir_p(File.join(dir, "elsewhere"))
      FileUtils.mkdir_p(File.dirname(devices.path, 2))
      File.symlink(File.join(dir, "elsewhere"), File.dirname(devices.path))

      expect(refusal { devices.pair("pixel") }).to include("is a symlink")
    end

    it "refuses a devices file others can read" do
      devices.pair("pixel")
      File.chmod(0o640, devices.path)

      expect(refusal { devices.pair("tablet") }).to include("must be mode 0600, not 0640")
    end

    it "leaves nothing staged beside the file" do
      devices.pair("pixel")

      expect(Dir.children(File.dirname(devices.path)).grep_v(/\A\.devices\.lock\z/)).to eq(["devices"])
    end
  end

  it "loses no pair and no revoke when many run at once" do
    %w[keep gone1 gone2].each { devices.pair(_1) }
    barrier, release = IO.pipe
    errors = File.join(dir, "child errors")
    at_barrier = lambda do |&work|
      ForkedChild.start(errors) do
        release.close
        barrier.read
        work.call
        0
      end
    end
    pids = Array.new(24) { |n| at_barrier.call { devices.pair("d#{n}") } } +
           %w[gone1 gone2].map { |name| at_barrier.call { devices.revoke(name) } }
    [barrier, release].each(&:close)
    statuses = pids.map { Process.wait2(_1).last.exitstatus }

    expect(File.exist?(errors) ? File.read(errors) : "").to eq("")
    expect(statuses.uniq).to eq([0])
    expect(paired_names.sort).to eq((["keep"] + Array.new(24) { "d#{_1}" }).sort)
  end

  it "refuses a devices file with a malformed line, naming the file and the line" do
    devices.pair("pixel")
    File.write(devices.path, "#{File.read(devices.path)}tablet\n")

    expect(refusal { devices.pair("watch") })
      .to eq("line 2 of the devices file #{devices.path} is not a device name and a token digest")
  end

  describe "#revoke" do
    it "drops only the named device's line" do
      devices.pair("pixel")
      tablet = devices.pair("tablet")
      devices.revoke("pixel")

      expect(File.read(devices.path)).to eq("tablet #{Lain::Ext.blake3_hex(tablet)}\n")
    end

    it "replaces the file rather than editing it in place, so a reader sees one whole version" do
      devices.pair("pixel")
      before = File.lstat(devices.path).ino
      devices.revoke("pixel")

      expect(File.lstat(devices.path).ino).not_to eq(before)
    end

    it "refuses a name that is not paired" do
      devices.pair("pixel")

      expect(refusal { devices.revoke("tablet") }).to eq("tablet is not paired")
    end
  end
end
