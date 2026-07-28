# frozen_string_literal: true

require "async"
require "fileutils"
require "msgpack"
require "socket"
require "tmpdir"

# The provisioning half of the exec boundary, as a CONTRACT rather than a
# hierarchy: #start hands back a connected socket, #stop describes the
# termination. Child is the incumbent implementation (it spawns a daemon);
# Transport::Mock is the attaching shape -- it provisions nothing, so a client
# built over it has no process to TERM and must terminate on its own read side.
RSpec.describe Lain::Core::Transport do
  let(:runtime_base) { Dir.mktmpdir("lain-core-transport") }
  let(:paths) { Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => runtime_base }) }

  after { FileUtils.rm_rf(runtime_base) }

  # A connected pair standing in for the wire: `ours` goes to the client
  # through the transport, `peer` is where a spec plays daemon (or hangs up).
  #
  # Always called INSIDE the reactor, so the ensure runs while it can still
  # reach a parked reader fiber. A regression that leaves one captive would
  # otherwise hang Sync's teardown forever instead of failing; closing both
  # ends here EOFs it, and the example fails in words (Async::TimeoutError).
  def wired(termination: Lain::Core::Transport::Mock::DEFAULT_TERMINATION)
    ours, peer = UNIXSocket.socketpair
    yield Lain::Core::Transport::Mock.new(socket: ours, termination:), peer
  ensure
    peer.close unless peer.closed?
    ours.close unless ours.closed?
  end

  # One scripted daemon reply: read the request frame, answer its msgid with a
  # ping result carrying `version`. Unpacker#read takes exactly one object, so
  # nothing needs to break out of a loop.
  def answer_ping(peer, version:)
    _kind, msgid, = MessagePack::Unpacker.new(peer).read
    peer.write(MessagePack.pack([Lain::Core::Client::RESPONSE, msgid, nil, { "version" => version }]))
  end

  # Reading the request frame before closing makes the call provably parked on
  # its promise when the wire dies -- no sleep, no race.
  def hang_up_on_first_request(peer)
    MessagePack::Unpacker.new(peer).read
    peer.close
  end

  # The rescue lives inside the task, so the death is consumed there rather
  # than re-raised (with a console warning) out of Task#wait.
  def capture_death(&call)
    call.call
    nil
  rescue Lain::Core::Died => e
    e.message
  end

  # Park a call, hang up under it, and report what Core::Died said, under a
  # bound. The task is reclaimed in the ensure: a regression that leaves the
  # caller parked forever would otherwise hang Sync's teardown rather than fail.
  def death_under_hangup(task, client, peer)
    in_flight = Async { capture_death { client.call("ping") } }
    hang_up_on_first_request(peer)
    task.with_timeout(2) { in_flight.wait }
  ensure
    in_flight.stop
  end

  describe "the contract" do
    # With no base class to inherit, this is the repo's only guard against the
    # two implementations drifting apart, so it pins ARITY as well as the names:
    # a transport that grew a required argument would satisfy `include` and
    # still break every call site.
    it "is two nullary messages, satisfied by the incumbent Child and by Mock alike" do
      [Lain::Core::Child, Lain::Core::Transport::Mock].each do |implementation|
        expect(implementation.instance_method(:start).arity).to eq(0)
        expect(implementation.instance_method(:stop).arity).to eq(0)
      end
    end

    it "answers #start with an IO the caller may own" do
      ours, peer = UNIXSocket.socketpair
      expect(Lain::Core::Transport::Mock.new(socket: ours).start).to be(ours)
    ensure
      peer.close
      ours.close
    end

    it "does not carry #pid: the caller holds the transport and asks it directly" do
      expect(Lain::Core::Client.instance_methods).not_to include(:pid)
      expect(Lain::Core::Child.instance_methods).to include(:pid)
    end
  end

  # Scenario: stopping a client whose transport owns no process still terminates
  it "terminates a client over a transport that only holds a socket, and reports it stopped" do
    Sync do |task|
      wired do |transport, _peer|
        socket = transport.start
        client = Lain::Core::Client.new(transport:, socket:)
        # The bound is the assertion: nothing here TERMs a daemon, so only the
        # client collapsing its own read side can end the reader fiber.
        task.with_timeout(2) { client.stop }
        # Exactly twice, because a voluntary stop travels BOTH release paths:
        # #stop sends it, the collapse EOFs the reader, and #perish sends it
        # again. `>= 1` would be satisfied by #perish alone, leaving "#stop
        # releases the transport" unpinned.
        expect(transport.stops).to eq(2)
        # close_read is a shutdown, not a close, so the fd survives it -- only
        # the trailing #close reclaims it, and nothing else in this example does.
        expect(socket).to be_closed
        expect { client.call("ping") }.to raise_error(Lain::Core::Client::Stopped, /stopped/)
      end
    end
  end

  # A transport that raises from #stop must not strand the reader fiber on a
  # live socket: Sync would never return, and the whole reactor hangs. T5's
  # attaching transport closes a socket in there, which is one IOError away.
  it "completes teardown even when the transport's own stop raises, and re-raises after" do
    Sync do |task|
      wired do |transport, _peer|
        socket = transport.start
        client = Lain::Core::Client.new(transport:, socket:)
        allow(transport).to receive(:stop).and_raise(IOError, "the far end was already gone")
        task.with_timeout(2) do
          expect { client.stop }.to raise_error(IOError, /already gone/)
        end
        expect(socket).to be_closed
      end
    end
  end

  # The same raise on the other release path. A spontaneous wire death reaches
  # #perish, whose job is to resolve every parked caller; a transport raising
  # there escapes into the reader task instead, stranding those callers forever
  # AND dumping an unhandled-task JSON blob onto stderr -- the Journal-interleave
  # hazard {Client#drain} already names. So the raise becomes the death's own
  # description rather than replacing it.
  it "resolves parked callers when the transport raises while reporting a spontaneous death" do
    Sync do |task|
      wired do |transport, peer|
        client = Lain::Core::Client.new(transport:, socket: transport.start)
        allow(transport).to receive(:stop).and_raise(IOError, "the far end was already gone")
        expect(death_under_hangup(task, client, peer)).to include("the far end was already gone")
      end
    end
  end

  # Scenario: a transport's termination description reaches the operator
  describe "a transport's termination description" do
    # Kill the wire under a parked call and report what Core::Died said.
    def death_message(termination)
      Sync do |task|
        wired(termination:) do |transport, peer|
          client = Lain::Core::Client.new(transport:, socket: transport.start)
          death_under_hangup(task, client, peer)
        end
      end
    end

    it "reaches the operator, so two transports' deaths read differently" do
      spawned = death_message("pid 4242 exit status 7")
      attached = death_message("vsock peer at cid 1 port 5252 hung up")
      expect(spawned).to include("pid 4242 exit status 7")
      expect(attached).to include("vsock peer at cid 1 port 5252 hung up")
      expect(spawned).not_to eq(attached)
    end
  end

  # Scenario: a version mismatch is still refused at the handshake
  it "refuses a daemon reporting another protocol version, naming both, leaving nothing captive" do
    Sync do |task|
      wired do |transport, peer|
        daemon = Async { answer_ping(peer, version: "999.0.0") }
        # The whole start is bounded: a reader fiber left captive by the failed
        # handshake would park #stop here rather than let the refusal out.
        task.with_timeout(2) do
          expect { Lain::Core::Client.start(transport:, handshake_budget: 1.0) }
            .to raise_error(Lain::Core::Client::VersionMismatch) do |error|
              expect(error.message).to include("999.0.0", Lain::Core::Client::PROTOCOL_VERSION)
            end
        end
        daemon.wait
        # Same two paths as a voluntary stop: the failed handshake calls #stop,
        # whose collapse EOFs the reader into #perish.
        expect(transport.stops).to eq(2)
      end
    end
  end

  # Scenario: the incumbent transport is unchanged
  describe "the incumbent transport", :core do
    it "spawns, handshakes, execs and stops exactly as before when injected as the transport" do
      child = Lain::Core::Child.new(paths:, binary: Lain::Core::Child::BINARY)
      Sync do
        client = Lain::Core::Client.start(transport: child)
        begin
          expect(client.call("ping").fetch("version")).to eq(Lain::Core::Client::PROTOCOL_VERSION)
          expect(client.call("exec", [{ "argv" => %w[echo hi] }]).fetch("stdout")).to eq("hi\n")
        ensure
          client.stop
        end
      end
      expect(child.pid).to be_a(Integer)
      expect { Process.kill(0, child.pid) }.to raise_error(Errno::ESRCH)
    end
  end
end
