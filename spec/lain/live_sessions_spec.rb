# frozen_string_literal: true

require "json"
require "tmpdir"

RSpec.describe Lain::LiveSessions do
  around do |example|
    Dir.mktmpdir("lain-live") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@dir, "state") }) }
  let(:sessions) { described_class.new(paths:) }
  let(:writer) { Lain::Liveness::Writer.current }

  def record(id: "20261116T100000-1", root: "/work/api", attended: true, started_at: "2026-11-16T10:00:00Z", **over)
    described_class::Record.new(session_id: id, pid: writer.pid, start: writer.start, host: writer.host, root:,
                                cwd: root, input_socket: attended ? "/run/lain/input.sock" : nil,
                                journal: "/state/#{id}.ndjson", attended:, started_at:, **over)
  end

  def live_file(id) = File.join(paths.state_home, "live", "#{id}.json")

  describe "#enter" do
    it "writes the record as live/<session id>.json and leaves no temp file" do
      sessions.enter(record)

      expect(JSON.parse(File.read(live_file("20261116T100000-1")))).to include(
        "session_id" => "20261116T100000-1", "pid" => writer.pid, "root" => "/work/api", "attended" => true,
        "input_socket" => "/run/lain/input.sock", "journal" => "/state/20261116T100000-1.ndjson",
        "started_at" => "2026-11-16T10:00:00Z"
      )
      expect(Dir.children(File.dirname(live_file("x")))).to eq(["20261116T100000-1.json"])
    end

    it "writes the record readable by its owner alone" do
      sessions.enter(record)

      expect(File.stat(live_file("20261116T100000-1")).mode & 0o777).to eq(0o600)
    end

    it "returns a handle whose leave removes the file, and leaving twice is harmless" do
      handle = sessions.enter(record)

      handle.leave
      handle.leave

      expect(File.exist?(live_file("20261116T100000-1"))).to be(false)
    end
  end

  describe "#each" do
    it "yields live records newest started_at first" do
      sessions.enter(record(id: "a", started_at: "2026-11-16T09:00:00Z"))
      sessions.enter(record(id: "b", started_at: "2026-11-16T11:00:00Z"))

      expect(sessions.map(&:session_id)).to eq(%w[b a])
    end

    it "skips a same-host record whose pid is dead and does not delete it" do
      sessions.enter(record(id: "crashed", start: "1"))

      expect(sessions.to_a).to be_empty
      expect(File.exist?(live_file("crashed"))).to be(true)
    end

    it "skips a record from another host and leaves its file" do
      sessions.enter(record(id: "elsewhere", host: "another-host.invalid", start: "1"))

      expect(sessions.to_a).to be_empty
      expect(File.exist?(live_file("elsewhere"))).to be(true)
    end

    it "skips a file it cannot parse" do
      FileUtils.mkdir_p(File.dirname(live_file("x")))
      File.write(live_file("torn"), "{")

      expect(sessions.to_a).to be_empty
    end

    it "yields nothing before the directory exists" do
      expect(sessions.to_a).to be_empty
    end
  end

  describe "#in" do
    it "returns the attended records of one checkout root only" do
      sessions.enter(record(id: "mine"))
      sessions.enter(record(id: "headless", attended: false))
      sessions.enter(record(id: "other", root: "/work/web"))

      expect(sessions.in("/work/api").map(&:session_id)).to eq(%w[mine])
    end
  end
end
