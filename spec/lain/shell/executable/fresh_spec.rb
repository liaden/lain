# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

RSpec.describe Lain::Shell::Executable::Fresh do
  around do |example|
    Dir.mktmpdir("fresh-root") do |root|
      @root = File.realpath(root)
      example.run
    end
  end

  attr_reader :root

  # A lineage that starts after every file this spec makes, so only a write
  # record can make one fresh; and one that starts before all of them.
  let(:after_every_file) { "2099-01-01T00:00:00.000000Z" }
  let(:before_every_file) { "2000-01-01T00:00:00.000000Z" }

  def session_file(name, *records, start:, resumed_from: nil)
    header = { "ts" => start, "type" => "session", "resumed_from" => resumed_from }.compact
    path = File.join(root, name)
    File.write(path, [header, *records].map { |record| "#{JSON.generate(record)}\n" }.join)
    path
  end

  def plant(name)
    path = File.join(root, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#!/bin/sh\n")
    path
  end

  def written(path) = Lain::Telemetry::FileWritten.from_stat(File.stat(path), path:, tool_use_id: "tu_1")

  def lineage_from(start) = described_class.for_lineage([session_file("s1.ndjson", start:)])

  describe "a write record seen live on the session's journal" do
    let(:journal) { Lain::Journal.new(io: StringIO.new) }
    let(:fresh) { lineage_from(after_every_file) }

    before { journal.observe(fresh) }

    it "makes the written file fresh even after touch -d sets its mtime back" do
      file = plant("bin/cat")
      journal << written(file)
      File.utime(Time.utc(2020), Time.utc(2020), file)

      expect(fresh.fresh?(file)).to be(true)
    end

    it "makes a bash redirect's file fresh, from the same record shape" do
      file = plant("out.txt")
      journal << written(file).to_journal

      expect(fresh.fresh?(file)).to be(true)
    end

    it "makes a link fresh when the file it lands in was written" do
      file = plant("real/cat")
      File.symlink(file, File.join(root, "cat"))
      journal << written(file)

      expect(fresh.fresh?(File.join(root, "cat"))).to be(true)
    end
  end

  describe "a file no write record names" do
    it "is fresh when its ctime is after the lineage's first record" do
      file = plant("bin/cat")

      expect(lineage_from(before_every_file).fresh?(file)).to be(true)
    end

    it "is not fresh when its ctime is before the lineage's first record" do
      file = plant("bin/cat")

      expect(lineage_from(after_every_file).fresh?(file)).to be(false)
    end
  end

  describe "a resumed lineage of 2 session files" do
    it "remembers a write the first file recorded" do
      file = plant("bin/cat")
      first = session_file("s1.ndjson", written(file).to_journal, start: after_every_file)
      second = session_file("s2.ndjson", start: after_every_file, resumed_from: { "file" => "s1.ndjson" })

      expect(described_class.for_lineage([first, second]).fresh?(file)).to be(true)
    end
  end

  describe "a lineage whose files start at different times" do
    it "starts at the oldest file's first record" do
      file = plant("bin/cat")
      first = session_file("s1.ndjson", start: before_every_file)
      second = session_file("s2.ndjson", start: after_every_file, resumed_from: { "file" => "s1.ndjson" })

      expect(described_class.for_lineage([first, second]).fresh?(file)).to be(true)
    end
  end

  describe "a session file read under a US-ASCII locale" do
    around do |example|
      external = Encoding.default_external
      Encoding.default_external = Encoding::US_ASCII
      example.run
    ensure
      Encoding.default_external = external
    end

    it "still matches a write record whose path is not ASCII" do
      file = plant("café/é")
      path = session_file("s1.ndjson", written(file).to_journal, start: after_every_file)

      fresh = described_class.for_lineage([path])

      expect([file, plant("untouched")].map { |each| fresh.fresh?(each) }).to eq([true, false])
    end
  end

  describe "its own fault" do
    it "answers every path fresh once a record it cannot fold arrives, and the journal records why" do
      io = StringIO.new
      journal = Lain::Journal.new(io:)
      fresh = lineage_from(after_every_file)
      journal.observe(fresh)

      journal << { "type" => "file_written", "path" => nil }

      expect(fresh.fresh?(plant("bin/cat"))).to be(true)
      expect(journal_records(io))
        .to include(include("type" => "journal_error", "observer" => described_class.name))
    end

    it "answers every path fresh when a lineage file cannot be read, and records why" do
      faults = []
      fresh = described_class.for_lineage([File.join(root, "missing.ndjson")], faults:)

      expect(fresh.fresh?(plant("bin/cat"))).to be(true)
      expect(faults).to contain_exactly(include("type" => "journal_error", "error" => /ENOENT/))
    end

    it "answers every path fresh when a write record in the lineage is torn" do
      path = session_file("s1.ndjson", start: after_every_file)
      File.write(path, %({"ts":"#{after_every_file}","type":"file_written"\n), mode: "a")

      expect(described_class.for_lineage([path]).fresh?(plant("bin/cat"))).to be(true)
    end

    it "reports itself degraded when a write record in the lineage is torn" do
      path = session_file("s1.ndjson", start: after_every_file)
      File.write(path, %({"ts":"#{after_every_file}","type":"file_written"\n), mode: "a")

      expect(described_class.for_lineage([path]).degraded?).to be(true)
    end

    it "reports itself degraded once a live record it cannot fold arrives" do
      fresh = lineage_from(after_every_file)

      expect { fresh << { "type" => "file_written", "path" => nil } }.to raise_error(TypeError)
      expect(fresh.degraded?).to be(true)
    end

    it "does not report a clean lineage degraded, and still answers by the rules" do
      fresh = lineage_from(after_every_file)

      expect(fresh.degraded?).to be(false)
      expect(fresh.fresh?(plant("bin/cat"))).to be(false)
    end

    it "answers a path fresh when it cannot stat it" do
      stat = Lain::Shell::Executable::Stat.new
      allow(stat).to receive(:lstat).and_raise(Errno::EACCES)
      fresh = described_class.for_lineage([session_file("s1.ndjson", start: after_every_file)], stat:)

      expect(fresh.fresh?(plant("bin/cat"))).to be(true)
    end
  end
end
