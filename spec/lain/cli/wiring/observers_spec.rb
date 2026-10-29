# frozen_string_literal: true

require "fileutils"
require "json"
require "stringio"
require "tmpdir"

RSpec.describe Lain::CLI::Wiring::Observers do
  around do |example|
    Dir.mktmpdir("wiring-observers") do |state|
      @state = File.realpath(state)
      example.run
    end
  end

  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @state }) }
  let(:project) { instance_double(Lain::Project, root: Dir.pwd) }
  let(:journal) { Lain::Journal.new(io: StringIO.new) }
  let(:chronicle) { Lain::CLI::Chronicle.new(journal:) }
  let(:file) { File.join(@state, "cat").tap { |path| File.write(path, "") } }
  let(:arms) { Lain::CLI::Arms::OFF }

  def resumed(name)
    Lain::CLI::Resume::Result.new(file: name, timeline: Lain::Dag::Factory.timeline(head_digest: nil, store: Lain::Dag::Factory.store),
                                  session: Lain::Session.new, open: false, notices: [],
                                  recorder: Lain::Memory::Recorder.new(index: Lain::Memory::Index.empty))
  end

  # A lineage that starts after every file here, so only a write record can
  # make one fresh.
  def lineage(name)
    header = { "ts" => "2099-01-01T00:00:00.000000Z", "type" => "session" }
    File.write(File.join(paths.sessions_dir, name), "#{JSON.generate(header)}\n")
    resumed(name)
  end

  it "folds the write records the session's journal writes into the lineage's Fresh" do
    observers = described_class.register(chronicle:, paths:, project:, resumed: lineage("first.ndjson"), arms:)

    expect(observers.fresh.fresh?(file)).to be(false)
    journal << Lain::Telemetry::FileWritten.from_stat(File.stat(file), path: file, tool_use_id: "tu_1")
    expect(observers.fresh.fresh?(file)).to be(true)
  end

  describe "a chat started from another directory with --root" do
    let(:root) { File.realpath(FileUtils.mkdir_p(File.join(@state, "project")).first) }
    let(:elsewhere) { File.realpath(FileUtils.mkdir_p(File.join(@state, "elsewhere")).first) }
    let(:chat) { instance_double(Lain::Project, root:) }

    def file_session(dir, name, resumed_from: nil)
      header = { "ts" => "2099-01-01T00:00:00.000000Z", "type" => "session" }
      header["resumed_from"] = { "file" => resumed_from, "head" => "blake3:#{"0" * 64}" } if resumed_from
      File.write(File.join(dir, name), "#{JSON.generate(header)}\n")
    end

    it "walks a resumed session filed under the root, with no journal_error" do
      file_session(paths.filing_dir(root:), "first.ndjson")
      file_session(paths.sessions_dir(project: paths.project_hash(elsewhere)), "first.ndjson",
                   resumed_from: "gone.ndjson")
      io = StringIO.new
      chronicle = Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io:))

      Dir.chdir(elsewhere) do
        described_class.register(chronicle:, paths:, project: chat, resumed: resumed("first.ndjson"), arms:)
      end

      expect(journal_records(io)).to be_empty
    end

    it "walks a chain whose parent is filed under the directory it was started in" do
      file_session(paths.sessions_dir(project: paths.project_hash(elsewhere)), "first.ndjson")
      file_session(paths.filing_dir(root:), "second.ndjson", resumed_from: "first.ndjson")
      io = StringIO.new
      chronicle = Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io:))

      Dir.chdir(elsewhere) do
        described_class.register(chronicle:, paths:, project: chat, resumed: resumed("second.ndjson"), arms:)
      end

      expect(journal_records(io)).to be_empty
    end
  end

  it "answers every path fresh when the resumed chain cannot be walked, and records why" do
    io = StringIO.new
    chronicle = Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io:))
    observers = described_class.register(chronicle:, paths:, project:, resumed: resumed("missing.ndjson"), arms:)

    expect(observers.fresh.fresh?(file)).to be(true)
    expect(journal_records(io))
      .to contain_exactly(include("type" => "journal_error", "observer" => Lain::Shell::Executable::Fresh.name))
  end

  describe "the tripwire ledger" do
    let(:io) { StringIO.new }
    let(:chronicle) { Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io:)) }

    def tripwires_after_a_remembered_deny(arms)
      described_class.register(chronicle:, paths:, project:, resumed: nil, arms:)
      chronicle.durable_journal << { "type" => "escalation", "tool" => "bash", "tool_use_id" => "tu_1",
                                     "requester" => "agent", "verdict" => "deny", "rung" => "remembered",
                                     "reason" => "", "final" => false }
      journal_records(io).select { _1["type"] == "tripwire" }
    end

    it "folds the session's journal into a ledger under --tripwire observe" do
      expect(tripwires_after_a_remembered_deny(Lain::CLI::Arms::OFF.with(tripwire: :observe)).sole)
        .to include("requester" => "agent", "signal" => "remembered_reask")
    end

    it "registers no ledger when the arm is off" do
      expect(tripwires_after_a_remembered_deny(Lain::CLI::Arms::OFF)).to be_empty
    end

    describe "under --tripwire stop" do
      def refused_exec_by(requester)
        chronicle.durable_journal << { "type" => "escalation", "tool" => "bash", "tool_use_id" => "tu_1",
                                       "requester" => requester, "verdict" => "allow", "rung" => "rules",
                                       "reason" => "", "final" => false }
        chronicle.durable_journal << {
          "type" => "exec_record", "tool_use_id" => "tu_1", "profile" => "reader",
          "execs" => [{ "path" => "/elsewhere/lain-fence", "argv0" => "lain-fence", "rc" => 0 }],
          "refusals" => [{ "path" => "/work/planted", "errno" => "EACCES" }], "fd_execs" => [],
          "truncated" => false, "incomplete" => false, "connects" => []
        }
      end

      it "stops a subagent that crosses the hard stop on a seeded signal, and pauses main" do
        observers = described_class.register(chronicle:, paths:, project:, resumed: nil,
                                             arms: Lain::CLI::Arms::OFF.with(tripwire: :stop))
        refused_exec_by("researcher")

        expect(%w[researcher agent].map { observers.stops.standing(_1) }).to eq(%i[stopped paused])
        expect(journal_records(io).select { _1["type"] == "tripwire_stop" }.sole)
          .to include("requester" => "researcher", "signal" => "refused_exec", "outcome" => "stopped")
      end

      it "holds stops that stop no one under --tripwire observe, and journals no stop" do
        observers = described_class.register(chronicle:, paths:, project:, resumed: nil,
                                             arms: Lain::CLI::Arms::OFF.with(tripwire: :observe))
        refused_exec_by("researcher")

        expect(observers.stops).to equal(Lain::Tripwire::Stops::None)
        types = journal_records(io).map { _1["type"] }
        expect([types.include?("tripwire"), types.include?("tripwire_stop")]).to eq([true, false])
      end
    end

    # Under --no-journal --nvim the teed records land in a journal the tee opens, not in the durable one.
    it "folds the teed journal as well as the durable one" do
      tee = Lain::Journal.new(io: StringIO.new)
      allow(Lain::Journal).to receive(:open).and_return(tee)
      ledgers = []
      allow(Lain::Tripwire::Ledger).to receive(:new).and_wrap_original do |new, **kwargs|
        new.call(**kwargs).tap { |ledger| ledgers << ledger }
      end
      null = Lain::CLI::Chronicle::Null.new
      described_class.register(chronicle: null, paths:, project:, resumed: nil,
                               arms: Lain::CLI::Arms::OFF.with(tripwire: :observe))
      null.wrap_tee(Lain::Channel.new)

      tee << { "type" => "escalation", "tool" => "bash", "tool_use_id" => "tu_1", "requester" => "agent",
               "verdict" => "deny", "rung" => "remembered", "reason" => "", "final" => false }

      expect(ledgers.sole.standing("agent").score).to be_positive
    end
  end

  describe "#notices" do
    it "says once that write records could not be read when a resumed line is torn" do
      name = "torn.ndjson"
      lineage(name)
      File.write(File.join(paths.sessions_dir, name), %({"type":"file_written"\n), mode: "a")
      observers = described_class.register(chronicle:, paths:, project:, resumed: resumed(name), arms:)

      expect(observers.notices)
        .to contain_exactly(match(/could not be read.*changed this session.*resume from an intact session/))
    end

    it "says the same when the resumed chain cannot be walked" do
      observers = described_class.register(chronicle:, paths:, project:, resumed: resumed("missing.ndjson"), arms:)

      expect(observers.notices).to contain_exactly(/write records could not be read/)
    end

    it "says nothing for a clean lineage" do
      observers = described_class.register(chronicle:, paths:, project:, resumed: lineage("first.ndjson"), arms:)

      expect(observers.notices).to be_empty
    end

    it "says nothing for a fresh chat" do
      expect(described_class.register(chronicle:, paths:, project:, resumed: nil, arms:).notices).to be_empty
    end

    describe "when the bash sandbox is built" do
      def sandbox_on(runner)
        fence = File.join(@state, "lain-fence")
        FileUtils.touch(fence)
        File.chmod(0o755, fence)
        probe = Lain::Confine::Probe.new(fence:, journal: chronicle.durable_journal, runner:,
                                         ptrace_scope: -> { "0" })
        Lain::Confine::Sandbox.new(root: @state, home: @state, masks: Lain::Confine::MaskList.new(root: @state,
                                                                                                  policy: -> {}),
                                   probe:, fence:, journal: chronicle.durable_journal)
                              .wrap(Lain::Exec::Local.new, requirer: "spec")
      end

      it "says once that bash runs unconfined, naming what the box lacks" do
        observers = described_class.register(chronicle:, paths:, project:, resumed: nil, arms:)
        sandbox_on(->(_argv) { ["", false] })

        expect(observers.notices).to contain_exactly(match(/lacks bwrap and landlock.*bash runs unconfined/))
      end

      it "says bash runs in the docker container, never unconfined, under --exec docker" do
        observers = described_class.register(chronicle:, paths:, project:, resumed: nil, arms:)
        chronicle.durable_journal << Lain::Telemetry::CapabilityDegraded.new(capability: :container,
                                                                             requirer: "spec", provider: "docker")

        expect(observers.notices).to eq(["bash runs in the docker container, not in the bash sandbox"])
      end

      describe "a project the workspace profile cannot seal" do
        let(:linked) do
          File.join(@state, "repo").tap do |root|
            FileUtils.mkdir_p(root)
            File.write(File.join(root, "shared-envrc"), "export X=1\n")
            File.symlink("shared-envrc", File.join(root, ".envrc"))
          end
        end
        let(:place) { instance_double(Lain::Project, root: linked) }

        def notices_under(confine)
          described_class.register(chronicle:, paths:, project: place, resumed: nil,
                                   arms: Lain::CLI::Arms::OFF.with(confine:)).notices
        end

        it "says once, under workspace, which link refuses every automatically approved call" do
          expect(notices_under(:workspace)).to contain_exactly(
            include(File.join(linked, ".envrc"), "--confine reader")
          )
        end

        it "says only that bash runs unconfined when the sandbox could not be built" do
          observers = described_class.register(chronicle:, paths:, project: place, resumed: nil,
                                               arms: Lain::CLI::Arms::OFF.with(confine: :workspace))
          sandbox_on(->(_argv) { ["", false] })

          expect(observers.notices).to contain_exactly(include("bash runs unconfined"))
        end

        it "says nothing under reader, which writes nothing there" do
          expect(notices_under(:reader)).to be_empty
        end

        it "says nothing under workspace once the link is a file" do
          File.unlink(File.join(linked, ".envrc"))
          File.write(File.join(linked, ".envrc"), "export X=1\n")

          expect(notices_under(:workspace)).to be_empty
        end
      end

      it "says nothing when the box offers every layer" do
        observers = described_class.register(chronicle:, paths:, project:, resumed: nil, arms:)
        sandbox_on(->(argv) { [argv.include?("--status") ? '{"abi":3,"reap":true}' : "", true] })

        expect(observers.notices).to be_empty
      end
    end
  end
end
