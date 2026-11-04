# frozen_string_literal: true

require "async"
require "msgpack"
require "socket"
require "fileutils"
require "tmpdir"

# A transport that attaches to a socket someone else listens on, so it owns
# no process: #start dials, #stop only reports.
RSpec.describe Lain::Core::Transport::Unix do
  around do |example|
    Dir.mktmpdir("unix-transport") do |dir|
      @path = File.join(dir, "relay.sock")
      example.run
    end
  end

  it "hands back a socket connected to whoever listens at the path" do
    server = UNIXServer.new(@path)
    socket = described_class.new(@path).start
    peer = server.accept
    socket.write("hi")

    expect(peer.read(2)).to eq("hi")
  ensure
    [socket, peer, server].compact.each(&:close)
  end

  it "refuses in its own words, naming the path, when nothing listens there" do
    expect { described_class.new(@path).start }
      .to raise_error(described_class::Unreachable, /#{Regexp.escape(@path)}/)
  end

  # A socket in a directory another user can write may be theirs, and whoever
  # answers there is handed what this side sends and believed in what it says.
  describe "a socket directory not this user's alone" do
    it "refuses a directory open to others, naming its mode" do
      File.chmod(0o755, File.dirname(@path))

      expect { described_class.new(@path).start }.to raise_error(described_class::Untrusted, /0755/)
    end

    it "refuses a directory reached through a symlink" do
      linked = "#{File.dirname(@path)}-link"
      File.symlink(File.dirname(@path), linked)

      expect { described_class.new(File.join(linked, "relay.sock")).start }
        .to raise_error(described_class::Untrusted, /symlink/)
    ensure
      FileUtils.rm_f(linked)
    end

    it "refuses a directory another user owns" do
      foreign = instance_double(File::Stat, symlink?: false, directory?: true, uid: Process.uid + 1, mode: 0o40700)
      allow(File).to receive(:lstat).and_call_original
      allow(File).to receive(:lstat).with(File.dirname(@path)).and_return(foreign)

      expect { described_class.new(@path).start }.to raise_error(described_class::Untrusted, /another user/)
    end
  end

  # The directory can be swapped between the check and the connect, so the
  # process that answered is checked too.
  describe "the process at the other end" do
    it "refuses a listener another user runs, and sends it nothing" do
      server = UNIXServer.new(@path)
      allow(UNIXSocket).to receive(:new).and_wrap_original do |original, *args|
        original.call(*args).tap { |socket| allow(socket).to receive(:getpeereid).and_return([Process.uid + 1, 0]) }
      end

      expect { described_class.new(@path).start }.to raise_error(described_class::Untrusted, /another user/)
      peer = server.accept
      expect(peer.read).to eq("")
    ensure
      [peer, server].compact.each(&:close)
    end

    it "closes the socket when the peer's credentials cannot be read" do
      server = UNIXServer.new(@path)
      dialled = []
      allow(UNIXSocket).to receive(:new).and_wrap_original do |original, *args|
        original.call(*args).tap do |socket|
          dialled << socket
          allow(socket).to receive(:getpeereid).and_raise(Errno::ENOTCONN)
        end
      end

      expect { described_class.new(@path).start }.to raise_error(described_class::Unreachable)
      expect(dialled.map(&:closed?)).to eq([true])
    ensure
      server&.close
    end

    it "connects to a listener this user runs" do
      server = UNIXServer.new(@path)
      socket = described_class.new(@path).start
      peer = server.accept

      expect([socket.getpeereid.first, peer.getpeereid.first]).to eq([Process.uid, Process.uid])
    ensure
      [socket, peer, server].compact.each(&:close)
    end
  end

  it "reports the same termination however often it is stopped, and kills nothing" do
    transport = described_class.new(@path)

    expect([transport.stop, transport.stop]).to eq(["detached from #{@path}"] * 2)
  end

  # The real client over it: the handshake, a call, and a stop that returns
  # though the far end never hangs up, since this transport has no process to end.
  it "carries a Core::Client round trip and a clean stop", :seam do
    server = UNIXServer.new(@path)
    daemon = Thread.new do
      peer = server.accept
      unpacker = MessagePack::Unpacker.new(peer)
      2.times do
        _kind, msgid, method, = unpacker.read
        result = method == "ping" ? { "version" => Lain::Core::Client::PROTOCOL_VERSION } : "pong"
        peer.write(MessagePack.pack([Lain::Core::Client::RESPONSE, msgid, nil, result]))
      end
      peer
    end

    answered = Sync do
      client = Lain::Core::Client.start(transport: described_class.new(@path))
      client.call("echo").tap { client.stop }
    end

    expect(answered).to eq("pong")
  ensure
    daemon&.value&.close
    server&.close
  end
end
