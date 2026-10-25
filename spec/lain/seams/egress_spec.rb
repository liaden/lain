# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "shellwords"
require "socket"
require "tmpdir"

# Each egress class is driven from inside the sandbox a chat builds, against a listener this
# spec owns. A listener that receives nothing proves nothing unless the same call reaches it
# unconfined, so the controls come first.
RSpec.describe "A reader call's egress", :seam do
  let(:fence) { Lain::Confine::Bwrap.fence_binary }
  let(:journal) { RecordingChannel.new }
  let(:probe) { Lain::Confine::Probe.new(fence:, journal:) }

  # Python is the client because it spells every socket call a probe needs, and it is on the
  # reader's read-only /usr.
  let(:clients) do
    {
      udp: <<~PY,
        import socket, sys, errno
        fam = socket.AF_INET6 if ":" in sys.argv[1] else socket.AF_INET
        try:
            s = socket.socket(fam, socket.SOCK_DGRAM)
            s.sendto(bytes.fromhex(sys.argv[3]), (sys.argv[1], int(sys.argv[2])))
            print("OK")
        except OSError as e:
            print(errno.errorcode.get(e.errno, e.errno))
      PY
      tcp: <<~PY,
        import socket, sys, errno
        try:
            s = socket.create_connection((sys.argv[1], int(sys.argv[2])), 2)
            s.send(b"tcp")
            print("OK")
        except OSError as e:
            print(errno.errorcode.get(e.errno, e.errno))
      PY
      unix: <<~PY,
        import socket, sys, errno
        try:
            s = socket.socket(socket.AF_UNIX)
            s.connect(sys.argv[1].replace("@", "\\0", 1))
            s.send(b"unix")
            print("OK")
        except OSError as e:
            print(errno.errorcode.get(e.errno, e.errno))
      PY
      sockets: <<~PY,
        import socket, errno
        for name, args in [("icmp", (socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_ICMP)),
                           ("sctp", (socket.AF_INET, socket.SOCK_STREAM, 132)),
                           ("mptcp", (socket.AF_INET, socket.SOCK_STREAM, 262))]:
            try:
                socket.socket(*args)
                print(name, "OPENED")
            except OSError as e:
                print(name, errno.errorcode.get(e.errno, e.errno))
      PY
      fast_open: <<~PY,
        import socket, sys, errno
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.sendto(b"tfo", 0x20000000, (sys.argv[1], int(sys.argv[2])))
            print("OK")
        except OSError as e:
            print(errno.errorcode.get(e.errno, e.errno))
      PY
      io_uring: <<~PY,
        import ctypes, errno
        libc = ctypes.CDLL(None, use_errno=True)
        params = ctypes.create_string_buffer(120)
        fd = libc.syscall(425, 8, params)
        print("io_uring_setup", "OPENED" if fd >= 0 else errno.errorcode.get(ctypes.get_errno()))
      PY
      get: <<~PY
        import http.client, sys
        c = http.client.HTTPConnection(sys.argv[1], int(sys.argv[2]), timeout=3)
        c.request("GET", "/")
        c.getresponse().read()
      PY
    }
  end

  let(:dns_query) { "\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x04exfl\x00\x00\x01\x00\x01".b }

  around do |example|
    Dir.mktmpdir("lain-egress") do |dir|
      @base = File.realpath(dir)
      @repo = File.join(@base, "repo")
      @home = File.join(@base, "home")
      FileUtils.mkdir_p([@repo, @home])
      example.run
    end
  end

  before do
    skip("bwrap, strace or python3 is not installed") unless %w[/usr/bin/bwrap /usr/bin/strace /usr/bin/python3]
                                                             .all? { File.executable?(_1) }
    skip("lain-fence is not built at #{fence} -- run `bundle exec rake compile`") unless File.executable?(fence)
    skip("bwrap cannot make a user namespace on this host") unless
      system("/usr/bin/bwrap", "--ro-bind", "/", "/", "--", "true", %i[out err] => File::NULL)
    if Lain::Confine::Sandbox.lacking(probe).any?
      skip("the box lacks #{Lain::Confine::Sandbox.lacking(probe).join(" and ")}")
    end
  end

  def mask_list
    policy = Lain::Sensitivity::Policy.new(
      sensitivity: Lain::Sensitivity.new(home: @home, cwd: @repo, root: @repo), home: @home, root: @repo
    )
    Lain::Confine::MaskList.new(root: @repo, policy: -> { policy })
  end

  def sandboxed
    Lain::Confine::Sandbox.new(root: @repo, home: @home, masks: mask_list, probe:, fence:, journal:)
                          .wrap(Lain::Exec::Local.new, requirer: "Spec")
  end

  def request
    ruling = Lain::Approval::Escalation::Ruling.allow(rung: "rules", because: "spec", rule: "composed_term")
    Lain::Confine::Request.new(ruling:, executables: [], cwd: @repo, root: @repo, tool_use_id: "toolu_egress")
  end

  def python(client, *args)
    "python3 -c #{clients.fetch(client).shellescape} #{args.map { _1.to_s.shellescape }.join(" ")}"
  end

  def confined(client, *args, exec: sandboxed)
    exec.call(command: python(client, *args), cwd: @repo, env: {}, timeout: 15, confinement: request)
  end

  def unconfined(client, *args)
    Lain::Exec::Local.new.call(command: python(client, *args), cwd: @repo, env: {}, timeout: 15)
  end

  def udp_listener(host)
    Socket.new(host.include?(":") ? :INET6 : :INET, :DGRAM).tap { _1.bind(Addrinfo.udp(host, 0)) }
  end

  def tcp_listener(host) = TCPServer.new(host, 0)

  def unix_listener(address)
    Socket.new(:UNIX, :STREAM).tap do |socket|
      socket.bind(Socket.sockaddr_un(address))
      socket.listen(1)
    end
  end

  def port(listener) = listener.local_address.ip_port

  def received?(listener)
    datagram = listener.is_a?(Socket) && listener.local_address.socktype == Socket::SOCK_DGRAM
    datagram ? datagram?(listener) : pending?(listener)
  end

  def datagram?(listener)
    listener.recv_nonblock(512, exception: false) != :wait_readable
  end

  def pending?(listener)
    listener.accept_nonblock(exception: false) != :wait_readable
  end

  def abstract_name = "@lain-egress-#{Process.pid}-#{SecureRandom.hex(4)}"

  def skip_below(abi, what)
    skip("#{what} needs Landlock ABI #{abi}; this kernel reports #{probe.abi}") if probe.abi < abi
  end

  describe "the listeners, unconfined" do
    it "reach every class of listener a confined call is denied" do
      status, = Open3.capture2e(fence, "--status")
      RSpec.configuration.reporter.message("egress probes run under: lain-fence --status #{status.strip}")
      udp4 = udp_listener("127.0.0.1")
      udp6 = udp_listener("::1")
      tcp = tcp_listener("127.0.0.1")
      fast_open = tcp_listener("127.0.0.1")
      abstract = abstract_name
      abstract_socket = unix_listener(abstract.sub("@", "\0"))
      path = File.join(@repo, "s")
      path_socket = unix_listener(path)

      unconfined(:udp, "127.0.0.1", port(udp4), "78")
      unconfined(:udp, "::1", port(udp6), "78")
      unconfined(:tcp, "127.0.0.1", port(tcp))
      unconfined(:fast_open, "127.0.0.1", port(fast_open))
      unconfined(:unix, abstract)
      unconfined(:unix, path)

      expect([udp4, udp6, tcp, fast_open, abstract_socket, path_socket].map { received?(_1) }).to all(be(true))
    end
  end

  it "cannot reach DNS by UDP" do
    resolver = udp_listener("127.0.0.1")
    capture = confined(:udp, "127.0.0.1", port(resolver), dns_query.unpack1("H*"))

    expect([capture.stdout.chomp, received?(resolver)]).to eq(["EPERM", false])
  end

  it "cannot reach UDP over v4 or v6" do
    v4 = udp_listener("127.0.0.1")
    v6 = udp_listener("::1")

    sent = [confined(:udp, "127.0.0.1", port(v4), "78"), confined(:udp, "::1", port(v6), "78")]

    expect([sent.map { _1.stdout.chomp }, received?(v4), received?(v6)]).to eq([%w[EPERM EPERM], false, false])
  end

  it "cannot reach loopback TCP" do
    listener = tcp_listener("127.0.0.1")

    capture = confined(:tcp, "127.0.0.1", port(listener))

    expect([capture.stdout.chomp, received?(listener)]).to eq(["EACCES", false])
  end

  it "cannot reach loopback TCP through Fast Open" do
    listener = tcp_listener("127.0.0.1")

    capture = confined(:fast_open, "127.0.0.1", port(listener))

    expect([capture.stdout.chomp, received?(listener)]).to eq(["EPERM", false])
  end

  it "cannot reach an abstract socket" do
    skip_below(6, "an abstract socket")
    name = abstract_name
    listener = unix_listener(name.sub("@", "\0"))

    capture = confined(:unix, name)

    expect([capture.stdout.chomp, received?(listener)]).to eq(["EPERM", false])
  end

  it "cannot reach a path socket" do
    skip_below(9, "a path socket")
    path = File.join(@repo, "s")
    listener = unix_listener(path)

    capture = confined(:unix, path)

    expect([capture.stdout.chomp, received?(listener)]).to eq(["EACCES", false])
  end

  it "cannot open ping, SCTP or MPTCP sockets" do
    capture = confined(:sockets)

    expect(capture.stdout.lines.map(&:chomp)).to eq(["icmp EPERM", "sctp EPERM", "mptcp EPERM"])
  end

  it "cannot reach the network through io_uring" do
    listener = udp_listener("127.0.0.1")

    capture = confined(:io_uring)

    expect([capture.stdout.chomp, received?(listener)]).to eq(["io_uring_setup EPERM", false])
  end

  describe "an allowed GET to a relay that POSTs onward" do
    # A port grant bounds where a call connects, not what the service behind the port does with it.
    let(:granting) do
      Struct.new(:profiles, :port) do
        def for(request) = profiles.for(request).with(connect_ports: [port])
      end
    end

    def granted(port)
      profiles = granting.new(Lain::Confine::Profiles.new(masks: mask_list, probe:, home: @home, root: @repo), port)
      launcher = Lain::Confine::Bwrap.new(fence:, bwrap: "/usr/bin/bwrap", strace: "/usr/bin/strace")
      Lain::Exec::Sandboxed.new(inner: Lain::Exec::Local.new, launcher:, profiles:, journal:)
    end

    it "reaches the sink, and the exec record names the granted port" do
      sink = tcp_listener("127.0.0.1")
      relay = tcp_listener("127.0.0.1")
      forwarder = Thread.new do
        client = relay.accept
        client.readpartial(1024)
        client.write("HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n")
        client.close
        TCPSocket.new("127.0.0.1", port(sink)).tap { _1.write("POST /out HTTP/1.0\r\n\r\nsecret") }.close
      end

      confined(:get, "127.0.0.1", port(relay), exec: granted(port(relay)))
      forwarder.join(5)
      posted = sink.accept_nonblock(exception: false)
      record = journal.events.grep(Lain::Telemetry::ExecRecord).last

      expect(posted).not_to eq(:wait_readable)
      expect(record.connects.map { _1[:port] }).to include(port(relay))
    ensure
      forwarder&.kill
    end
  end
end
