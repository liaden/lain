# frozen_string_literal: true

RSpec.describe Lain::Confine::Trace do
  def trace_io(lines) = StringIO.new("#{lines.join("\n")}\n")

  def record_of(lines, cap: described_class::CAP)
    described_class.new(trace_io(lines), cap:).record(tool_use_id: "toolu_1", profile: :reader)
  end

  let(:lines) do
    [
      '10 execve("/bin/sh", ["/bin/sh", "-c", "cat x"], 0x7ffd /* 84 vars */) = 0',
      '11 execve("/usr/bin/cat", ["cat", "x"], 0x55c1 /* 84 vars */) = 0',
      "11 +++ exited with 0 +++",
      "10 --- SIGCHLD {si_signo=SIGCHLD, si_code=CLD_EXITED} ---",
      '12 execve("P/bin/x", ["x"], 0x55c1 /* 84 vars */) = -1 EACCES (Permission denied)',
      '13 execveat(3, "", ["fdprog", "-v"], 0x55c1 /* 84 vars */, AT_EMPTY_PATH) = 0'
    ]
  end

  describe "connects" do
    def connects_of(*text_lines) = record_of(text_lines).connects

    def inet(port, address) = %({sa_family=AF_INET, sin_port=htons(#{port}), sin_addr=inet_addr("#{address}")})

    def entry(call, family, address, port, status: 0, errno: nil, count: 1)
      { call:, family:, address:, port:, rc: status, errno:, count: }
    end

    def msg(name) = %(sendmsg(3, {msg_name=#{name}, msg_iov=[{iov_base="x", iov_len=1}], msg_iovlen=1}, 0) = 1)

    it "records a connect to an IPv4 address with its rc" do
      expect(connects_of("5 connect(3, #{inet(8080, "127.0.0.1")}, 16) = 0"))
        .to eq([entry("connect", "AF_INET", "127.0.0.1", 8080)])
    end

    it "records a refused connect with its errno" do
      line = "5 connect(3, #{inet(9, "10.0.0.1")}, 16) = -1 EACCES (Permission denied)"
      expect(connects_of(line)).to eq([entry("connect", "AF_INET", "10.0.0.1", 9, status: -1, errno: "EACCES")])
    end

    it "records an IPv6 connect" do
      line = "5 connect(3, {sa_family=AF_INET6, sin6_port=htons(443), sin6_flowinfo=htonl(0), " \
             'inet_pton(AF_INET6, "::1", &sin6_addr), sin6_scope_id=0}, 28) = 0'
      expect(connects_of(line)).to eq([entry("connect", "AF_INET6", "::1", 443)])
    end

    it "records a Unix socket connect by its path, with no port" do
      expect(connects_of('5 connect(3, {sa_family=AF_UNIX, sun_path="/run/docker.sock"}, 110) = 0'))
        .to eq([entry("connect", "AF_UNIX", "/run/docker.sock", nil)])
    end

    it "marks an abstract Unix socket with a leading at sign" do
      expect(connects_of('5 connect(3, {sa_family=AF_UNIX, sun_path=@"dbus"}, 8) = 0').sole)
        .to include(address: "@dbus")
    end

    it "records a sendto that names an address" do
      expect(connects_of(%(5 sendto(3, "ping", 4, 0, #{inet(5353, "127.0.0.1")}, 16) = 4)))
        .to eq([entry("sendto", "AF_INET", "127.0.0.1", 5353, status: 4)])
    end

    it "records nothing for a send on a connected socket" do
      expect(connects_of('5 sendto(3, "x", 1, MSG_NOSIGNAL, NULL, 0) = 1', msg("NULL"))).to eq([])
    end

    it "does not read an address out of a payload that spells one" do
      payload = inet(1, "1.2.3.4").gsub('"', '\\"')
      expect(connects_of(%(5 sendto(3, "#{payload}", 70, 0, NULL, 0) = 70))).to eq([])
    end

    it "records a sendmsg that names an address" do
      line = "5 #{msg(inet(53, "8.8.8.8"))}"
      expect(connects_of(line)).to eq([entry("sendmsg", "AF_INET", "8.8.8.8", 53, status: 1)])
    end

    it "joins a connect that was unfinished to its resumed line" do
      expect(connects_of("5 connect(3, #{inet(80, "1.1.1.1")}, 16 <unfinished ...>",
                         "5 <... connect resumed>) = -1 EINPROGRESS (Operation now in progress)"))
        .to eq([entry("connect", "AF_INET", "1.1.1.1", 80, status: -1, errno: "EINPROGRESS")])
    end

    it "folds identical entries into one that counts them" do
      line = %(5 sendto(3, "x", 1, 0, #{inet(53, "8.8.8.8")}, 16) = 1)
      expect(connects_of(*[line] * 3)).to eq([entry("sendto", "AF_INET", "8.8.8.8", 53, status: 1, count: 3)])
    end

    it "keeps entries that differ in rc apart" do
      ok = "5 connect(3, #{inet(80, "1.1.1.1")}, 16) = 0"
      refused = "5 connect(3, #{inet(80, "1.1.1.1")}, 16) = -1 ECONNREFUSED (Connection refused)"
      expect(connects_of(ok, refused, ok).map { _1.values_at(:rc, :count) }).to eq([[0, 2], [-1, 1]])
    end

    it "keeps the first 256 distinct entries and counts those it dropped" do
      calls = (1..300).map { "5 connect(3, #{inet(_1, "1.1.1.1")}, 16) = 0" }
      record = record_of(calls)
      expect([record.connects.size, record.connects.first[:port], record.connects_dropped]).to eq([256, 1, 44])
    end

    it "folds a repeat of a kept entry even after the cap is reached" do
      calls = (1..300).map { "5 connect(3, #{inet(_1, "1.1.1.1")}, 16) = 0" }
      record = record_of([*calls, calls.first])
      expect([record.connects.first[:count], record.connects_dropped]).to eq([2, 44])
    end

    it "drops no entry when none passes the cap" do
      expect(record_of(["5 connect(3, #{inet(80, "1.1.1.1")}, 16) = 0"]).connects_dropped).to eq(0)
    end

    it "records the address of the first message of a sendmmsg" do
      line = "5 sendmmsg(3, [{msg_hdr={msg_name=#{inet(53, "9.9.9.9")}, msg_namelen=16, msg_iov=NULL, " \
             "msg_iovlen=0, msg_controllen=0, msg_flags=0}, msg_len=1}], 1, 0) = 1"
      expect(connects_of(line)).to eq([entry("sendmmsg", "AF_INET", "9.9.9.9", 53, status: 1)])
    end

    it "records nothing for a sendmmsg on a connected socket" do
      line = "5 sendmmsg(3, [{msg_hdr={msg_name=NULL, msg_namelen=0, msg_iov=NULL, msg_iovlen=0, " \
             "msg_controllen=0, msg_flags=0}}], 1, 0) = 1"
      expect(connects_of(line)).to eq([])
    end

    it "records only internet and Unix families" do
      netlink = "5 connect(5, {sa_family=AF_NETLINK, nl_pid=0, nl_groups=00000000}, 12) = 0"
      unspec = '5 connect(5, {sa_family=AF_UNSPEC, sa_data="\\0\\0"}, 16) = 0'
      expect(connects_of(netlink, unspec)).to eq([])
    end

    it "keeps connects out of the exec lists" do
      record = record_of([*lines, '5 connect(3, {sa_family=AF_UNIX, sun_path="/x"}, 110) = 0'])
      expect([record.execs.size, record.fd_execs.size, record.refusals.size]).to eq([3, 1, 1])
    end

    it "reports a connect still unfinished as incomplete" do
      expect(record_of(["5 connect(3, #{inet(80, "1.1.1.1")}, 16 <unfinished ...>"]).incomplete).to be(true)
    end
  end

  describe "#record" do
    it "lists every execve with path, argv0 and rc" do
      expect(record_of(lines).execs).to eq(
        [{ path: "/bin/sh", argv0: "/bin/sh", rc: 0 },
         { path: "/usr/bin/cat", argv0: "cat", rc: 0 },
         { path: "P/bin/x", argv0: "x", rc: -1 }]
      )
    end

    it "names a refused exec" do
      expect(record_of(lines).refusals).to eq([{ path: "P/bin/x", errno: "EACCES" }])
    end

    it "keeps an execveat on a descriptor apart" do
      expect(record_of(lines).fd_execs).to eq([{ fd: 3, path: "", argv0: "fdprog", rc: 0, errno: nil }])
    end

    it "carries the call it was read for and is not truncated" do
      record = record_of(lines)
      expect([record.tool_use_id, record.profile, record.truncated]).to eq(["toolu_1", :reader, false])
    end

    it "is complete when every exec it holds has closed" do
      expect(record_of(lines).incomplete).to be(false)
    end

    describe "read before its channel ended" do
      def record_unended(text_lines)
        described_class.new(trace_io(text_lines)).record(tool_use_id: "t", profile: :traced, ended: false)
      end

      it "is incomplete until its first process has exited" do
        expect(record_unended(lines).incomplete).to be(true)
      end

      it "is complete once its first process has exited, whatever it left running" do
        expect(record_unended([*lines, "10 +++ exited with 0 +++"]).incomplete).to be(false)
        expect(record_unended([*lines, "10 +++ killed by SIGKILL +++"]).incomplete).to be(false)
      end
    end

    it "is incomplete while an exec is still unfinished" do
      unfinished = '20 execve("/usr/bin/cat", ["cat"], 0x1 /* 1 var */ <unfinished ...>'
      expect(record_of([*lines, unfinished]).incomplete).to be(true)
    end

    it "is incomplete when its last line is cut short" do
      record = described_class.new(StringIO.new("#{lines.join("\n")}\n11 execve(\"/usr/b"))
                              .record(tool_use_id: "toolu_1", profile: :reader)
      expect(record.incomplete).to be(true)
    end

    it "does not count a failed lookup as a refusal" do
      missing = '14 execve("/nonexistent/x", ["x"], 0x1 /* 1 var */) = -1 ENOENT (No such file or directory)'
      record = record_of([missing])
      expect([record.execs.size, record.refusals]).to eq([1, []])
    end

    it "refuses an execveat on AT_FDCWD like an execve" do
      record = record_of(['40 execveat(AT_FDCWD, "/bin/x", ["x"], 0x1 /* 1 var */, 0) = -1 EACCES (Permission denied)'])
      expect([record.execs.pluck(:path), record.refusals]).to eq([["/bin/x"], [{ path: "/bin/x", errno: "EACCES" }]])
    end

    it "keeps the relative path and errno of an execveat on a descriptor" do
      record = record_of(['41 execveat(4, "rel/p", ["p"], 0x1 /* 1 var */, 0) = -1 EACCES (Permission denied)'])
      expect([record.fd_execs, record.refusals]).to eq(
        [[{ fd: 4, path: "rel/p", argv0: "p", rc: -1, errno: "EACCES" }], [{ path: "rel/p", errno: "EACCES" }]]
      )
    end

    it "joins an unfinished call to its resumed line" do
      record = record_of(
        ['20 execve("/usr/bin/cat", ["/usr/bin/cat"], 0x55 /* 84 vars */ <unfinished ...>',
         "21 +++ exited with 0 +++",
         "20 <... execve resumed>)           = 0"]
      )
      expect(record.execs).to eq([{ path: "/usr/bin/cat", argv0: "/usr/bin/cat", rc: 0 }])
    end

    it "joins a resumed refusal to its call" do
      record = record_of(
        ['20 execve("P/bin/x", ["x"], 0x55 /* 1 var */ <unfinished ...>',
         "20 <... execve resumed>)           = -1 EACCES (Permission denied)"]
      )
      expect(record.refusals).to eq([{ path: "P/bin/x", errno: "EACCES" }])
    end

    it "reads strace's escapes in a path and argv0" do
      record = record_of([+'30 execve("/tmp/a\"b\nc", ["q\\\\\"r\nz\t\x01"], 0x1 /* 1 var */) = 0'])
      expect(record.execs.first).to eq({ path: "/tmp/a\"b\nc", argv0: "q\\\"r\nz\t\u0001", rc: 0 })
    end

    it "reads an octal escape as its byte" do
      record = record_of(['31 execve("/tmp/\\303\\251", ["\\303\\251"], 0x1 /* 1 var */) = 0'])
      expect(record.execs.first[:path]).to eq("/tmp/é")
    end

    it "reads an argv0 strace cut short" do
      record = record_of(['32 execve("/bin/x", ["aaaa"..., "b"], 0x1 /* 1 var */) = 0'])
      expect(record.execs.first[:argv0]).to eq("aaaa")
    end

    it "reads a call with an empty argv" do
      record = record_of(['33 execve("/bin/x", [], 0x1 /* 1 var */) = 0'])
      expect(record.execs.first[:argv0]).to eq("")
    end

    it "ignores lines that are not exec calls" do
      expect(record_of(["garbage", ""]).execs).to be_empty
    end

    it "is deeply frozen" do
      expect(record_of(lines)).to be_deeply_frozen
    end

    context "when the trace passes the cap" do
      let(:many) { Array.new(50) { |i| %(#{i} execve("/usr/bin/p#{i}", ["p"], 0x1 /* 1 var */) = 0) } }

      it "stops parsing and says so" do
        record = record_of(many, cap: 300)
        expect([record.truncated, record.execs.size]).to eq([true, 5])
      end

      it "keeps draining the pipe past the cap" do
        reader, writer = IO.pipe
        thread = Thread.new do
          writer.write("#{many.join("\n")}\n" * 400)
          writer.close
        end
        record = described_class.new(reader, cap: 300).record(tool_use_id: "t", profile: :traced)
        thread.join
        expect([record.truncated, reader.eof?]).to eq([true, true])
      end

      it "is not truncated at exactly the cap" do
        text = "#{many.first}\n"
        record = described_class.new(StringIO.new(text), cap: text.bytesize).record(tool_use_id: "t", profile: :traced)
        expect([record.truncated, record.execs.size]).to eq([false, 1])
      end
    end
  end
end
