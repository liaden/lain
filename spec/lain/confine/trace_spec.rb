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
      expect(Ractor.shareable?(record_of(lines))).to be(true)
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
