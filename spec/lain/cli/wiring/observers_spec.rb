# frozen_string_literal: true

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
  let(:journal) { Lain::Journal.new(io: StringIO.new) }
  let(:chronicle) { Lain::CLI::Chronicle.new(journal:) }
  let(:file) { File.join(@state, "cat").tap { |path| File.write(path, "") } }
  let(:arms) { Lain::CLI::Arms::OFF }

  def resumed(name)
    Lain::CLI::Resume::Result.new(file: name, timeline: Lain::Timeline.new(head_digest: nil, store: Lain::Store.new),
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
    observers = described_class.register(chronicle:, paths:, resumed: lineage("first.ndjson"), arms:)

    expect(observers.fresh.fresh?(file)).to be(false)
    journal << Lain::Telemetry::FileWritten.from_stat(File.stat(file), path: file, tool_use_id: "tu_1")
    expect(observers.fresh.fresh?(file)).to be(true)
  end

  it "answers every path fresh when the resumed chain cannot be walked, and records why" do
    io = StringIO.new
    chronicle = Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io:))
    observers = described_class.register(chronicle:, paths:, resumed: resumed("missing.ndjson"), arms:)

    expect(observers.fresh.fresh?(file)).to be(true)
    expect(journal_records(io))
      .to contain_exactly(include("type" => "journal_error", "observer" => Lain::Shell::Executable::Fresh.name))
  end

  describe "the tripwire ledger" do
    let(:io) { StringIO.new }
    let(:chronicle) { Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io:)) }

    def tripwires_after_a_remembered_deny(arms)
      described_class.register(chronicle:, paths:, resumed: nil, arms:)
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

    # Under --no-journal --nvim the teed records land in a journal the tee opens, not in the durable one.
    it "folds the teed journal as well as the durable one" do
      tee = Lain::Journal.new(io: StringIO.new)
      allow(Lain::Journal).to receive(:open).and_return(tee)
      ledgers = []
      allow(Lain::Tripwire::Ledger).to receive(:new).and_wrap_original do |new, **kwargs|
        new.call(**kwargs).tap { |ledger| ledgers << ledger }
      end
      null = Lain::CLI::Chronicle::Null.new
      described_class.register(chronicle: null, paths:, resumed: nil,
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
      observers = described_class.register(chronicle:, paths:, resumed: resumed(name), arms:)

      expect(observers.notices)
        .to contain_exactly(match(/could not be read.*changed this session.*resume from an intact session/))
    end

    it "says the same when the resumed chain cannot be walked" do
      observers = described_class.register(chronicle:, paths:, resumed: resumed("missing.ndjson"), arms:)

      expect(observers.notices).to contain_exactly(/write records could not be read/)
    end

    it "says nothing for a clean lineage" do
      observers = described_class.register(chronicle:, paths:, resumed: lineage("first.ndjson"), arms:)

      expect(observers.notices).to be_empty
    end

    it "says nothing for a fresh chat" do
      expect(described_class.register(chronicle:, paths:, resumed: nil, arms:).notices).to be_empty
    end
  end
end
