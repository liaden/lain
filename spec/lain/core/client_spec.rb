# frozen_string_literal: true

require "async"
require "msgpack"
require "socket"
require "tempfile"

RSpec.describe Lain::Core::Client do
  def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # The peer plays the daemon over one end of a socketpair; the client gets the
  # other through a Mock transport, which owns no process to TERM.
  def with_client(termination: Lain::Core::Transport::Mock::DEFAULT_TERMINATION)
    Sync do
      ours, peer = UNIXSocket.socketpair
      transport = Lain::Core::Transport::Mock.new(socket: ours, termination:)
      begin
        yield transport, peer
      ensure
        peer.close unless peer.closed?
        ours.close unless ours.closed?
      end
    end
  end

  def respond(peer, msgid, result: nil, error: nil)
    peer.write(MessagePack.pack([Lain::Core::Client::RESPONSE, msgid, error, result]))
  end

  def ping_result = { "version" => Lain::Core::Client::PROTOCOL_VERSION }

  # Answers the handshake ping, then hands back the unpacker for the calls after it.
  def answer_handshake(peer)
    requests = MessagePack::Unpacker.new(peer)
    _kind, msgid, = requests.read
    respond(peer, msgid, result: ping_result)
    requests
  end

  # Starts a client against a peer that answers the handshake, then runs the
  # block with the client and the peer's request stream.
  def with_handshaken_client(**options)
    with_client(**options) do |transport, peer|
      daemon = Async { answer_handshake(peer) }
      client = described_class.start(transport:)
      requests = daemon.wait
      begin
        yield client, peer, requests
      ensure
        client.stop
      end
    end
  end

  it "demuxes replies that arrive out of order, each to its own caller" do
    with_handshaken_client do |client, peer, requests|
      daemon = Async do
        asked = Array.new(2) { requests.read }
        asked.reverse_each { |_kind, msgid, method,| respond(peer, msgid, result: "reply to #{method}") }
      end
      first = Async { client.call("first") }
      second = Async { client.call("second") }
      expect([first.wait, second.wait]).to eq(["reply to first", "reply to second"])
      daemon.wait
    end
  end

  it "fails in-flight and subsequent calls with Core::Died carrying the transport's account" do
    with_handshaken_client(termination: "peer vanished") do |client, peer, requests|
      in_flight = Async do
        expect { client.call("slow") }.to raise_error(Lain::Core::Died, /peer vanished/)
      end
      requests.read
      peer.close
      in_flight.wait
      expect { client.call("ping") }.to raise_error(Lain::Core::Died, /peer vanished/)
    end
  end

  it "surfaces a server error reply as Refused, verbatim, without hurting the connection" do
    with_handshaken_client do |client, peer, requests|
      daemon = Async do
        _kind, msgid, = requests.read
        respond(peer, msgid, error: "unknown method: no_such_method")
        _kind, msgid, = requests.read
        respond(peer, msgid, result: ping_result)
      end
      expect { client.call("no_such_method") }
        .to raise_error(Lain::Core::Client::Refused, /no_such_method/)
      expect(client.call("ping").fetch("version")).to eq(Lain::Core::Client::PROTOCOL_VERSION)
      daemon.wait
    end
  end

  # Pre-fix, a malformed frame killed the reader silently: the in-flight caller
  # parked forever AND Async's console logger dumped the task failure onto
  # stderr, which the AST spec cannot see because async writes it, not lain.
  it "fails loudly on undecodable frames instead of parking callers or leaking to stderr" do
    captured = capturing_parent_stderr do
      with_client do |transport, peer|
        peer.write("\xC1garbage".b)
        expect { described_class.start(transport:) }
          .to raise_error(Lain::Core::Died, /released/)
      end
    end
    expect(captured).to eq("")
  end

  # accept-then-silence would otherwise park Client.start forever.
  it "bounds the handshake: a peer that never answers fails in the budget's words" do
    with_client do |transport, peer|
      started = monotonic_now
      expect { described_class.start(transport:, handshake_budget: 0.3) }
        .to raise_error(Lain::Core::Client::HandshakeTimeout, /0\.3/)
      expect(monotonic_now - started).to be < 2.0
      expect(peer).not_to be_closed
    end
  end

  it "distinguishes a voluntary stop: calls after #stop raise Stopped, not Died" do
    with_handshaken_client do |client|
      client.stop
      expect { client.call("ping") }.to raise_error(Lain::Core::Client::Stopped, /stopped/)
    end
  end

  # The one example with no double between client and daemon: it pins the
  # Ruby-to-Rust msgpack contract the wire exists to carry.
  it "speaks the real binary's wire: handshake, ping, and a refusal of a method it does not serve", :core do
    Sync do
      daemon = CoreDaemon.new
      client = described_class.start(transport: daemon)
      begin
        expect(client.call("ping")).to include("version" => Lain::Core::Client::PROTOCOL_VERSION, "pid" => Integer)
        expect { client.call("exec", [{ "argv" => %w[echo hi] }]) }
          .to raise_error(Lain::Core::Client::Refused, /unknown method "exec"/)
      ensure
        client.stop
      end
    end
  end

  private

  # Redirect the process-level fd 2 -- what a spawned child would inherit --
  # into a tempfile for the duration. Reassigning $stderr to a StringIO would
  # only catch Ruby-side writes.
  def capturing_parent_stderr
    absorb_experimental_io_buffer_warning
    capture = Tempfile.new("lain-core-stderr")
    backup = $stderr.dup
    $stderr.reopen(capture.path, "w")
    yield
    $stderr.flush
    File.read(capture.path)
  ensure
    restore_stderr(backup, capture)
  end

  def restore_stderr(backup, capture)
    $stderr.reopen(backup)
    backup.close
    capture.close!
  end

  # Ruby's once-per-process "IO::Buffer is experimental" warning fires on the
  # FIRST scheduler-hooked read anywhere in the process; trigger it before
  # capturing so the capture holds only what the client wrote.
  def absorb_experimental_io_buffer_warning
    IO::Buffer.new(1)
  end
end
