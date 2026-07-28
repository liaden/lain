# frozen_string_literal: true

require "async"
require "socket"

# The attaching half of the Transport contract, over the socket family the seam
# exists for. Every example drives the REAL compiled lain-core, reached over
# AF_VSOCK rather than a filesystem path -- so what is under test is not this
# class in isolation but the whole exec boundary with the wire swapped.
#
# Tagged :vsock and NOTHING else. A command-line --tag lifts the config-level
# exclusion for the tag it names and no other, so a second tag here would keep
# every example excluded under `--tag vsock` and the run would pass green having
# executed nothing (spec/support/tags.rb spells this out at length).
RSpec.describe Lain::Core::Transport::Vsock, :vsock do
  def with_client(port:, **options)
    Sync do
      client = Lain::Core::Client.start(transport: described_class.new(port:), **options)
      begin
        yield client
      ensure
        client.stop
      end
    end
  end

  def exec_params(*argv)
    [{ "argv" => argv }]
  end

  def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def procfs_or_skip
    skip "no /proc/self/fd on this host -- descriptor-leak check needs procfs" unless Dir.exist?("/proc/self/fd")
  end

  # A port the kernel itself confirms has no listener: bind ephemerally, read
  # back what was assigned, and hand the port over having released it. Nothing
  # else can claim it in between, and a hardcoded literal could not make the
  # claim at all -- vsock ports are a host-global namespace with no per-test
  # scoping, so a leaked daemon from another run would make an example pass for
  # entirely the wrong reason.
  #
  # The struct layout comes from the class under test, not from the spec-support
  # copy: two spellings of an address whose own comment warns that a silent
  # mismatch binds a DIFFERENT address would be exactly the drift that comment is
  # about. VMADDR_PORT_ANY stays with VsockAvailability, which is the module that
  # BINDS -- a dialer has no use for it.
  def released_port
    socket = Socket.new(Socket::AF_VSOCK, Socket::SOCK_STREAM, 0)
    begin
      socket.bind([Socket::AF_VSOCK, 0, VsockAvailability::VMADDR_PORT_ANY, described_class::VMADDR_CID_ANY,
                   0, 0, 0, 0].pack(described_class::SOCKADDR_VM))
      socket.getsockname.unpack(described_class::SOCKADDR_VM)[2]
    ensure
      socket.close
    end
  end

  it "carries the handshake over a real AF_VSOCK stream" do
    VsockDaemon.run do |daemon|
      with_client(port: daemon.port) do |client|
        expect(client.call("ping").fetch("version")).to eq(Lain::Core::Client::PROTOCOL_VERSION)
      end
    end
  end

  # `sh` is dash, whose printf implements POSIX \ooo but NOT bash's \xNN -- with
  # hex it emits the escape text verbatim, which reads exactly like a transport
  # corrupting bytes. The comparison is on .b because msgpack `bin` arrives
  # BINARY-encoded and String#== is false across encodings for non-ASCII bytes
  # even when every byte agrees.
  it "carries NUL and high bytes unaltered" do
    VsockDaemon.run do |daemon|
      with_client(port: daemon.port) do |client|
        stdout = client.call("exec", exec_params("sh", "-c", 'printf "a\000b\376\377z"')).fetch("stdout")
        expect(stdout.b).to eq("a\x00b\xFE\xFFz".b)
      end
    end
  end

  it "carries a mebibyte of stdout without truncating it" do
    mebibyte = 1024 * 1024
    expected = ("lain\n" * ((mebibyte / 5) + 1)).byteslice(0, mebibyte)
    VsockDaemon.run do |daemon|
      with_client(port: daemon.port) do |client|
        stdout = client.call("exec", exec_params("sh", "-c", "yes lain | head -c #{mebibyte}")).fetch("stdout")
        expect(stdout.bytesize).to eq(mebibyte)
        expect(stdout.b).to eq(expected.b)
      end
    end
  end

  # Each command sleeps for LONGER the EARLIER it was issued, so the daemon
  # answers in reverse order: only msgid demux can then hand every fiber its own
  # result, and a transport that quietly serialized or misrouted frames shows up
  # as a mismatched token rather than as a timing wobble. No latency assertion --
  # measured round trips are 60-160us and any threshold would flake.
  it "keeps eight concurrent calls on one connection matched to their callers" do
    tokens = (0...8).map { |index| "token-#{index}" }
    VsockDaemon.run do |daemon|
      with_client(port: daemon.port) do |client|
        answers = tokens.each_with_index
                        .map { |token, index| Async { call_after(client, 0.08 - (index * 0.01), token) } }
                        .map(&:wait)
        expect(answers).to eq(tokens)
      end
    end
  end

  # There is no reliable connect-time refusal on vsock_loopback. Measured on this
  # kernel, dialing a just-released port raised ECONNRESET 3 of 5 times in a bare
  # loop and SUCCEEDED 39 of 40 times through this transport -- and where it
  # succeeded, the first write raised ENOTCONN instead. ECONNREFUSED, the
  # TCP/Unix intuition, never appears at all. So the transport may not depend on
  # connect failing, and this example may not pin which of the two shapes it gets
  # (both were exercised: 39 Core::Died, 1 Unreachable, all bounded). What it CAN
  # pin is the pair's common contract: the start fails in bounded time, and
  # whichever error arrives names the far end it was dialing -- the only
  # diagnostic an operator has for a wrong port.
  #
  # A THIRD branch exists that this example cannot reach and does not assert: a
  # far end that ACCEPTS and then stays MUTE -- a wedged lain-core in a guest,
  # which is the shape this transport exists for. That fails HandshakeTimeout,
  # whose message names the budget but NOT the cid or port, so these assertions
  # would not match it. The AC holds here only because vsock_loopback resets
  # sub-millisecond, which is not a property of any real hypervisor's vsock. The
  # fix belongs to Client -- have HandshakeTimeout carry the transport's report
  # the way Died does -- and is filed as a ticket rather than worked around here.
  it "fails bounded, naming the far end, when nothing is listening" do
    port = released_port
    started = monotonic_now
    expect { with_client(port:, handshake_budget: 0.3) { |client| client.call("ping") } }
      .to raise_error(Lain::Error, /vsock/i) { |error| expect(error.message).to include("cid 1", "port #{port}") }
    # Well under Client::HANDSHAKE_BUDGET, so the ceiling can only be met if the
    # injected 0.3 was honoured -- a ceiling of 2.0 is numerically the default
    # and would pass whether or not the budget reached the client at all.
    expect(monotonic_now - started).to be < 1.0
  end

  # The deterministic kill for "#stop reports the far end". The example above
  # pins the same string, but only on the branch where the kernel happens to
  # refuse the dial -- on the other branch Unreachable builds its message from
  # far_end DIRECTLY, so #stop can be gutted and that example still passes
  # (measured: gutting it survived 2 of 10 and 5 of 12 runs). Killing the daemon
  # under a live client is the one path where #stop's return value is the ONLY
  # source of the address: Client#perish asks the transport what happened and
  # interpolates the answer into Core::Died.
  it "names the far end in Core::Died when the daemon it attached to dies" do
    VsockDaemon.run do |daemon|
      port = daemon.port
      Sync do
        client = Lain::Core::Client.start(transport: described_class.new(port:))
        begin
          expect(client.call("ping").fetch("version")).to eq(Lain::Core::Client::PROTOCOL_VERSION)
          daemon.stop
          expect { client.call("ping") }.to raise_error(Lain::Core::Died, /AF_VSOCK cid 1 port #{port}\z/)
        ensure
          client.stop
        end
      end
    end
  end

  # Not one of the card's five scenarios: it exists because mutating the
  # refusal-wrapping away left the suite GREEN 10 runs in 12. The dead-port
  # example cannot pin that wrapping, because it reaches the refusal only
  # sometimes and never on purpose -- but a VACANT cid is refused ENODEV every
  # time, which makes the same code path deterministic. What it pins is that a
  # refused dial says WHICH address was wrong: a bare Errno reaching the caller
  # names no cid and no port, and a wrong address is the likeliest cause of a
  # refusal there is.
  #
  # CID_ANY is the vacant cid used here BECAUSE it can never become occupied:
  # ENODEV is a property of a cid nothing answers on, not of any particular
  # number, and the hypervisor-selection chunk assigns guest cids from 3 upward
  # -- a literal picked out of that range goes red the day a guest lands on it.
  # CID_ANY is a bind-side wildcard and is not a dialable address at all.
  #
  # The descriptor count rides along because nothing else can see it: a dial
  # that raised without closing its socket leaks one fd per attempt, silently,
  # and this transport is built one-per-connection.
  it "names the far end, leaking no descriptor, when the dial itself is refused" do
    procfs_or_skip
    port = released_port
    vacant = described_class::VMADDR_CID_ANY
    before_count = Dir.children("/proc/self/fd").size
    50.times do
      expect { described_class.new(port:, cid: vacant).start }
        .to raise_error(described_class::Unreachable, /AF_VSOCK cid #{vacant} port #{port}/)
    end
    expect(Dir.children("/proc/self/fd").size).to eq(before_count)
  end

  # The descriptor guarantee is UNCONDITIONAL, not a list of the exceptions
  # worth closing for -- an earlier version rescued SystemCallError alone and
  # leaked one fd per call on every other path (measured: 50 dials with a String
  # port took the process from 7 open descriptors to 57, raising out of
  # Array#pack). #initialize now coerces port and cid, so no real argument can
  # make connect raise anything but a SystemCallError any more; stubbing the
  # raise is what keeps the guarantee a fact rather than a promise the next edit
  # is free to break.
  it "reclaims the descriptor whatever the dial raises, not only a refusal" do
    procfs_or_skip
    port = released_port
    allow_any_instance_of(Socket).to receive(:connect).and_raise(TypeError, "not an address")
    before_count = Dir.children("/proc/self/fd").size
    50.times { expect { described_class.new(port:).start }.to raise_error(TypeError) }
    expect(Dir.children("/proc/self/fd").size).to eq(before_count)
  end

  # A String port is the realistic caller -- argv, a config file, the decimal
  # text the daemon publishes -- so it is coerced, base-10 EXPLICITLY, because
  # Integer("012345") is octal 5349 in Ruby and a zero-padded field would
  # otherwise dial a different port in silence. A value that is not a number at
  # all fails at CONSTRUCTION naming itself, rather than surviving to #start and
  # arriving as a TypeError out of Array#pack: "could not be dialled" would be a
  # lie about something that was never an address, and this class's whole premise
  # is that its errors name the far end truthfully.
  it "coerces a decimal-string port and refuses a value that is not a number" do
    expect(described_class.new(port: "012345").far_end).to include("port 12345")
    expect { described_class.new(port: "no-such-port") }.to raise_error(ArgumentError, /no-such-port/)
    expect { described_class.new(port: 5252, cid: nil) }.to raise_error(TypeError, /nil/)
  end

  private

  def call_after(client, delay, token)
    client.call("exec", exec_params("sh", "-c", "sleep #{delay}; printf %s #{token}")).fetch("stdout")
  end
end
