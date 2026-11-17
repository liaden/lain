# frozen_string_literal: true

require "async"

RSpec.describe Lain::LiveSessions do
  let(:paths) { Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => "/run/user/7" }) }
  let(:writer) { Lain::Liveness::Writer.current }

  def record(id: "20261116T100000-1", root: "/work/api", attended: true, started_at: "2026-11-16T10:00:00Z")
    described_class::Record.new(session_id: id, pid: writer.pid, start: writer.start, host: writer.host, root:,
                                cwd: root, input_socket: attended ? "/run/lain/input.sock" : nil,
                                journal: "/state/#{id}.ndjson", attended:, started_at:)
  end

  def over(*records)
    @client = SessionListing.new(records)
    described_class.new(paths:, daemon: -> { @client })
  end

  describe "#each" do
    it "yields what the daemon lists, newest started_at first" do
      sessions = over(record(id: "a", started_at: "2026-11-16T09:00:00Z"),
                      record(id: "b", started_at: "2026-11-16T11:00:00Z"))

      expect(sessions.map(&:session_id)).to eq(%w[b a])
      expect(@client.asked).to eq(["session.list"])
    end

    it "yields every field the daemon sends" do
      expect(over(record).first).to eq(record)
    end

    it "hangs up the connection it listed over" do
      over(record).to_a

      expect(@client).to be_stopped
    end

    it "yields nothing, and says why once, when the daemon cannot be reached" do
      notes = StringIO.new
      sessions = described_class.new(paths:, notes:, daemon: -> { raise Lain::Daemon::Unstarted, "did not answer" })

      expect(sessions.to_a).to be_empty
      expect(notes.string.lines).to eq(["cannot list the running chats: did not answer\n"])
    end

    it "yields nothing, and hangs up, when the daemon refuses the listing" do
      refusing = SessionListing.new
      allow(refusing).to receive(:call).and_raise(Lain::Core::Client::Refused, "only the daemon's own user")
      notes = StringIO.new

      expect(described_class.new(paths:, notes:, daemon: -> { refusing }).to_a).to be_empty
      expect(refusing).to be_stopped
      expect(notes.string).to include("only the daemon's own user")
    end

    it "yields nothing when there is no daemon" do
      sessions = described_class.new(paths:, daemon: -> { Lain::Daemon::Absent.new(reason: "the daemon is off") })

      expect(sessions.to_a).to be_empty
    end
  end

  describe "#in" do
    it "returns the attended records of one checkout root only" do
      sessions = over(record(id: "mine"), record(id: "headless", attended: false),
                      record(id: "other", root: "/work/web"))

      expect(sessions.in("/work/api").map(&:session_id)).to eq(%w[mine])
    end
  end

  describe "against the real daemon", :daemon do
    it "lists a chat while its registration holds, and not once its connection ends" do
      sessions = described_class.new(paths: daemon_paths)
      registration = Lain::Daemon::Registration.new(
        record:, notes: StringIO.new,
        daemon: lambda { |pushes:, replace:|
          Lain::Daemon.ensure(paths: daemon_paths, env: daemon_env, pushes:, replace:)
        }
      )

      Sync do |task|
        registration.open(task)
        expect(sessions.to_a).to eq([record])
        registration.close
        pumped_until(task, reason: "the session dropped") { sessions.none? }
      end
    end
  end
end
