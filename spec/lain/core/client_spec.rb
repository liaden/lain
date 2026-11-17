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

  describe "#wait" do
    it "parks while the connection lives and calls go on being answered" do
      with_handshaken_client do |client, peer, requests|
        waiting = Async { client.wait }
        daemon = Async do
          _kind, msgid, = requests.read
          respond(peer, msgid, result: "served")
        end
        expect(client.call("ping")).to eq("served")
        daemon.wait

        expect(waiting).to be_running
      end
    end

    it "returns the Died that says why once the far end hangs up" do
      with_handshaken_client(termination: "peer vanished") do |client, peer|
        waiting = Async { client.wait }
        peer.close

        expect(waiting.wait).to be_a(Lain::Core::Died).and(having_attributes(message: /peer vanished/))
      end
    end

    it "returns Stopped once the client is stopped" do
      with_handshaken_client do |client|
        waiting = Async { client.wait }
        client.stop

        expect(waiting.wait).to be_a(Lain::Core::Client::Stopped)
      end
    end
  end

  describe "pushed frames" do
    def push(peer, method, params) = peer.write(MessagePack.pack([Lain::Core::Client::PUSH, method, params]))

    def with_pushing_client(**options)
      with_client do |transport, peer|
        daemon = Async { answer_handshake(peer) }
        client = described_class.start(transport:, **options)
        requests = daemon.wait
        begin
          yield client, peer, requests
        ensure
          client.stop
        end
      end
    end

    it "delivers a push to the subscriber queue as method and params, once" do
      pushes = Async::Queue.new
      with_pushing_client(pushes:) do |_client, peer|
        push(peer, "offer", [{ "id" => 1 }])
        expect(pushes.dequeue).to eq(["offer", [{ "id" => 1 }]])
        expect(pushes).to be_empty
      end
    end

    it "resolves a pending call whether the push lands before or after its response" do
      pushes = Async::Queue.new
      with_pushing_client(pushes:) do |client, peer, requests|
        daemon = Async do
          2.times do |round|
            _kind, msgid, = requests.read
            push(peer, "before", [round]) if round.zero?
            respond(peer, msgid, result: "reply #{round}")
            push(peer, "after", [round]) if round == 1
          end
        end
        expect([client.call("a"), client.call("b")]).to eq(["reply 0", "reply 1"])
        daemon.wait
        expect([pushes.dequeue, pushes.dequeue]).to eq([["before", [0]], ["after", [1]]])
      end
    end

    it "drops a push with no subscriber and says so in 1 note" do
      notes = StringIO.new
      with_pushing_client(notes:) do |client, peer, requests|
        push(peer, "offer", [1])
        push(peer, "offer", [2])
        daemon = Async do
          _kind, msgid, = requests.read
          respond(peer, msgid, result: "still served")
        end
        expect(client.call("ping")).to eq("still served")
        daemon.wait
        expect(notes.string.lines.size).to eq(1)
        expect(notes.string).to match(/push.*offer.*no subscriber/i)
      end
    end

    it "drops a malformed push instead of handing it to the subscriber" do
      pushes = Async::Queue.new
      with_pushing_client(pushes:) do |client, peer, requests|
        [[2], [2, nil, nil], [2, 5, 7], [2, "a"], [2, "a", [1], "extra"], [2, "a", "notarray"]].each do |frame|
          peer.write(MessagePack.pack(frame))
        end
        push(peer, "offer", [1])
        expect(pushes.dequeue).to eq(["offer", [1]])
        expect(pushes).to be_empty
        daemon = Async do
          _kind, msgid, = requests.read
          respond(peer, msgid, result: "ok")
        end
        expect(client.call("ping")).to eq("ok")
        daemon.wait
      end
    end

    it "treats a closed queue as no subscriber and keeps resolving calls" do
      pushes = Async::Queue.new
      notes = StringIO.new
      with_pushing_client(pushes:, notes:) do |client, peer, requests|
        pushes.close
        push(peer, "offer", [1])
        daemon = Async do
          _kind, msgid, = requests.read
          respond(peer, msgid, result: "still served")
        end
        expect(client.call("ping")).to eq("still served")
        daemon.wait
        expect(notes.string.lines.size).to eq(1)
      end
    end
  end

  # The one example with no double between client and daemon: it pins the
  # Ruby-to-Rust msgpack contract the wire exists to carry.
  it "speaks the real binary's wire: handshake, ping, and a refusal of a method it does not serve", :core, :daemon do
    Sync do
      client = Lain::Daemon.ensure(paths: daemon_paths, env: daemon_env)
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
    capture = Tempfile.new("lain-daemon-stderr")
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
