# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Lain::Isolation::LeaseLock do
  describe ".parse" do
    it "reads a lease back into the pid, start and host it names" do
      lock = described_class.parse("lain-lease pid=42 start=9001 host=box")

      expect(lock).to eq(described_class::Held.new(pid: 42, start: "9001", host: "box"))
      expect(lock.reason).to eq("lain-lease pid=42 start=9001 host=box")
    end

    it "reads a retention back into when it began" do
      lock = described_class.parse("lain-retained since=2026-09-01T10:00:00Z")

      expect(lock.since).to eq(Time.utc(2026, 9, 1, 10))
      expect(lock.reason).to eq("lain-retained since=2026-09-01T10:00:00Z")
    end

    it "calls a bare lock, a lock lain did not write, or a garbled time foreign" do
      ["", "someone else's", "lain-lease pid=x start=1 host=h", "lain-retained since=yesterday"].each do |reason|
        expect(described_class.parse(reason)).to be_a(described_class::Foreign)
      end
    end

    it "answers unlocked for a worktree git holds no lock on" do
      expect(described_class.parse(nil)).to equal(described_class::UNLOCKED)
    end

    it "is deeply frozen" do
      expect(described_class.parse("lain-lease pid=42 start=9001 host=box")).to be_deeply_frozen
    end
  end

  describe "which locks hold a worktree against reaping" do
    let(:table) { instance_double(Lain::Isolation::LeaseLock::ProcessTable) }
    let(:held) { described_class::Held.new(pid: 42, start: "9001", host: "box") }

    it "holds for a lease whose process is live, and says which" do
      allow(table).to receive(:verdict).with(held).and_return(:live)

      expect([held.held?(table), held.why(table)]).to eq([true, "leased by live process 42 on box"])
    end

    it "holds for a lease taken on another host, which this one cannot judge" do
      allow(table).to receive(:verdict).with(held).and_return(:elsewhere)

      expect([held.held?(table), held.why(table)]).to eq([true, "leased on another host (box)"])
    end

    it "releases a lease whose process is dead, aged from the checkout" do
      allow(table).to receive(:verdict).with(held).and_return(:dead)
      created = Time.utc(2026, 9, 1)

      expect([held.held?(table), held.aged_from(created)]).to eq([false, created])
    end

    it "releases a retention, aged from its own since" do
      retained = described_class.parse("lain-retained since=2026-09-03T00:00:00Z")

      expect([retained.held?(table), retained.aged_from(Time.utc(2026, 9, 1))]).to eq([false, Time.utc(2026, 9, 3)])
    end

    it "holds for a foreign lock, naming its reason" do
      foreign = described_class.parse("someone else's")

      expect([foreign.held?(table), foreign.why(table)])
        .to eq([true, "locked by something lain did not write (\"someone else's\")"])
    end

    it "says a lease whose process has exited is dead, rather than calling it another host's" do
      allow(table).to receive(:verdict).with(held).and_return(:dead)

      expect(held.why(table)).to eq("leased by process 42 on box, which has exited")
    end

    it "completes the duck on every shape: why a lock holds or not, and where its age counts from" do
      created = Time.utc(2026, 9, 1)
      retained = described_class.parse("lain-retained since=2026-09-03T00:00:00Z")

      expect(described_class.parse("x").aged_from(created)).to eq(created)
      expect(retained.why(table)).to eq("retained since 2026-09-03T00:00:00Z")
      expect(described_class::UNLOCKED.why(table)).to eq("not locked")
    end

    it "releases an unlocked worktree, aged from the checkout" do
      expect([described_class::UNLOCKED.held?(table), described_class::UNLOCKED.aged_from(Time.utc(2026, 9, 1))])
        .to eq([false, Time.utc(2026, 9, 1)])
    end
  end

  describe Lain::Isolation::LeaseLock::ProcessTable do
    around do |example|
      Dir.mktmpdir("lain-proc") do |proc_root|
        @proc_root = proc_root
        example.run
      end
    end

    # `/proc/<pid>/stat`: field 22 is the start time in clock ticks. The command
    # name in field 2 may hold spaces and parentheses, which is why the fields
    # are counted from the LAST `)`.
    def stat(pid, start)
      FileUtils.mkdir_p(File.join(@proc_root, pid.to_s))
      File.write(File.join(@proc_root, pid.to_s, "stat"),
                 "#{pid} (odd (name) here) S #{(4..21).to_a.join(" ")} #{start} 0 0\n")
    end

    def signal_for(alive) = ->(_signal, pid) { alive.fetch(pid) { raise Errno::ESRCH } }

    def table(pid: 42, alive: {}, host: "box")
      described_class.new(pid:, host:, proc_root: @proc_root, signal: signal_for(alive))
    end

    it "names the current process as a lease: its pid, start time and host" do
      stat(42, 777)

      expect(table.current).to eq(Lain::Isolation::LeaseLock::Held.new(pid: 42, start: "777", host: "box"))
    end

    it "records an unreadable start as unknown rather than guessing" do
      expect(table.current.start).to eq("-")
    end

    it "calls a lease live when its host, pid and start time all match" do
      stat(42, 777)

      expect(table(alive: { 42 => 1 }).verdict(table.current)).to eq(:live)
    end

    it "calls a lease live when the pid exists but belongs to another user" do
      stat(42, 777)
      denied = described_class.new(pid: 42, host: "box", proc_root: @proc_root,
                                   signal: ->(*) { raise Errno::EPERM })

      expect(denied.verdict(table.current)).to eq(:live)
    end

    it "calls a lease dead when its pid is gone" do
      stat(42, 777)
      lease = table.current
      FileUtils.rm_rf(File.join(@proc_root, "42"))

      expect(table.verdict(lease)).to eq(:dead)
    end

    it "calls a lease dead when its pid was reused by a later process" do
      stat(42, 777)
      lease = table.current
      stat(42, 999)

      expect(table(alive: { 42 => 1 }).verdict(lease)).to eq(:dead)
    end

    it "calls a lease live when the start time cannot be compared, on pid existence alone" do
      unknown = Lain::Isolation::LeaseLock::Held.new(pid: 42, start: "-", host: "box")

      expect(table(alive: { 42 => 1 }).verdict(unknown)).to eq(:live)
    end

    it "never judges a lease taken on another host" do
      stat(42, 777)

      expect(table(host: "other").verdict(table.current)).to eq(:elsewhere)
    end
  end
end
