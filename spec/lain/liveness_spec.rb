# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "socket"

RSpec.describe Lain::Liveness do
  # A pid that existed a moment ago and has exited.
  def dead_pid = Process.spawn("true").tap { |pid| Process.wait(pid) }

  def own_start = Lain::Liveness::Probe.new.start_of(Process.pid)

  describe ".of, against this machine's real process table" do
    it "calls this process live against the start it really has" do
      expect(described_class.of(Process.pid, started_at: own_start)).to eq(:live)
    end

    it "calls a pid that has exited dead" do
      expect(described_class.of(dead_pid, started_at: own_start)).to eq(:dead)
    end

    it "calls this pid dead against a start it does not have, since only a reuse could differ" do
      expect(described_class.of(Process.pid, started_at: "1")).to eq(:dead)
    end
  end

  describe Lain::Liveness::Probe do
    around do |example|
      Dir.mktmpdir("lain-proc") do |proc_root|
        @proc_root = proc_root
        example.run
      end
    end

    # `/proc/<pid>/stat`, whose field 22 is the start in clock ticks since boot;
    # the command name in field 2 may hold spaces and parentheses.
    def stat(pid, start)
      FileUtils.mkdir_p(File.join(@proc_root, pid.to_s))
      File.write(File.join(@proc_root, pid.to_s, "stat"),
                 "#{pid} (odd (name) here) S #{(4..21).to_a.join(" ")} #{start} 0 0\n")
    end

    def probe(signal: ->(_signal, pid) { raise Errno::ESRCH unless pid == 42 })
      described_class.new(proc_root: @proc_root, signal:)
    end

    it "calls a pid live when it exists and its start matches" do
      stat(42, 777)

      expect(probe.of(42, started_at: "777")).to eq(:live)
    end

    it "calls a pid live when it exists but belongs to another user, rather than dead" do
      stat(42, 777)
      denied = probe(signal: ->(*) { raise Errno::EPERM })

      expect(denied.of(42, started_at: "777")).to eq(:live)
    end

    it "calls a pid dead when it is gone" do
      expect(probe.of(7, started_at: "777")).to eq(:dead)
    end

    it "calls a pid dead when a later process reused it" do
      stat(42, 999)

      expect(probe.of(42, started_at: "777")).to eq(:dead)
    end

    it "answers unknown when a start cannot be compared, on either side" do
      expect(probe.of(42, started_at: "777")).to eq(:unknown)

      stat(42, 777)
      expect(probe.of(42, started_at: Lain::Liveness::UNKNOWN_START)).to eq(:unknown)
    end

    it "calls a pid too large for any process dead, rather than raising" do
      expect(described_class.new(proc_root: @proc_root).of(99_999_999_999_999_999_999, started_at: "1")).to eq(:dead)
    end

    # The boot time /proc/stat reports is recomputed from the wall clock at
    # every read, so a step of that clock moves it. A start in ticks is on the
    # boot clock, which nothing here converts, so the step changes no verdict.
    it "keeps a live writer live after the wall clock steps forward by hours" do
      FileUtils.mkdir_p(File.join(@proc_root, Process.pid.to_s))
      File.write(File.join(@proc_root, Process.pid.to_s, "stat"), File.read("/proc/#{Process.pid}/stat"))
      File.write(File.join(@proc_root, "stat"),
                 File.read("/proc/stat").sub(/^btime (\d+)$/) { "btime #{Integer(Regexp.last_match(1)) + (3 * 3600)}" })

      writer = Lain::Liveness::Writer.current
      expect(writer.verdict(described_class.new(proc_root: @proc_root))).to eq(:live)
    end
  end

  describe Lain::Liveness::Writer do
    it "names this process: its pid, its start and this host" do
      expect(described_class.current).to eq(described_class.new(pid: Process.pid, start: own_start,
                                                                host: Socket.gethostname))
    end

    it "rides in a session header as one field, and reads back from it" do
      writer = described_class.new(pid: 42, start: "777", host: "box")

      expect(writer.to_header).to eq("writer" => { "pid" => 42, "start" => "777", "host" => "box" })
      expect(described_class.from_header({ "type" => "session" }.merge(writer.to_header))).to eq(writer)
    end

    it "is live for this process and dead for one that has exited" do
      expect(described_class.current.verdict).to eq(:live)
      expect(described_class.new(pid: dead_pid, start: own_start, host: Socket.gethostname).verdict).to eq(:dead)
    end

    it "judges nothing for a writer on another host" do
      expect(described_class.new(pid: dead_pid, start: "1", host: "elsewhere.invalid").verdict).to eq(:unknown)
    end

    # Absence, not a guess: whatever the file's name says, a header that never
    # recorded its writer cannot prove that writer gone.
    it "reads a header that records no writer, or a garbled one, as unrecorded and unknown" do
      garbled = { "writer" => { "pid" => "x", "start" => "1", "host" => "h" } }
      [{ "type" => "session" }, { "writer" => "pid 42" }, garbled, { "writer" => { "pid" => 42 } }].each do |header|
        writer = described_class.from_header(header)

        expect([writer, writer.pid, writer.verdict, writer.to_header])
          .to eq([described_class::UNRECORDED, nil, :unknown, {}])
      end
    end

    # A start that is not a tick count can never match a real one, so reading
    # it would call this very process dead.
    it "reads a header whose writer start is null, empty or not a tick count as unrecorded" do
      [nil, "", "abc"].each do |start|
        fields = { "writer" => { "pid" => Process.pid, "start" => start, "host" => Socket.gethostname } }
        writer = described_class.from_header(fields)

        expect([writer, writer.verdict]).to eq([described_class::UNRECORDED, :unknown])
      end
    end

    it "is deeply frozen" do
      expect(described_class.current).to be_deeply_frozen
    end
  end
end
