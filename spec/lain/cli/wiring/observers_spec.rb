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
    observers = described_class.register(chronicle:, paths:, resumed: lineage("first.ndjson"))

    expect(observers.fresh.fresh?(file)).to be(false)
    journal << Lain::Telemetry::FileWritten.from_stat(File.stat(file), path: file, tool_use_id: "tu_1")
    expect(observers.fresh.fresh?(file)).to be(true)
  end

  it "answers every path fresh when the resumed chain cannot be walked, and records why" do
    io = StringIO.new
    chronicle = Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io:))
    observers = described_class.register(chronicle:, paths:, resumed: resumed("missing.ndjson"))

    expect(observers.fresh.fresh?(file)).to be(true)
    expect(journal_records(io))
      .to contain_exactly(include("type" => "journal_error", "observer" => Lain::Shell::Executable::Fresh.name))
  end

  describe "#notices" do
    it "says once that write records could not be read when a resumed line is torn" do
      name = "torn.ndjson"
      lineage(name)
      File.write(File.join(paths.sessions_dir, name), %({"type":"file_written"\n), mode: "a")
      observers = described_class.register(chronicle:, paths:, resumed: resumed(name))

      expect(observers.notices)
        .to contain_exactly(match(/could not be read.*changed this session.*resume from an intact session/))
    end

    it "says the same when the resumed chain cannot be walked" do
      observers = described_class.register(chronicle:, paths:, resumed: resumed("missing.ndjson"))

      expect(observers.notices).to contain_exactly(/write records could not be read/)
    end

    it "says nothing for a clean lineage" do
      observers = described_class.register(chronicle:, paths:, resumed: lineage("first.ndjson"))

      expect(observers.notices).to be_empty
    end

    it "says nothing for a fresh chat" do
      expect(described_class.register(chronicle:, paths:, resumed: nil).notices).to be_empty
    end
  end
end
