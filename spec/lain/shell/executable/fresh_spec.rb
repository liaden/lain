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

  describe "#any_under?" do
    let(:project) { File.join(root, "project").tap { FileUtils.mkdir_p(_1) } }
    let(:journal) { Lain::Journal.new(io: StringIO.new) }

    def lineage(start)
      described_class.for_lineage([session_file("s1.ndjson", start:)]).tap { journal.observe(_1) }
    end

    def made(relative)
      path = File.join(project, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "x\n")
      path
    end

    # The filesystem stamps a ctime from a coarse clock, so a gap either side keeps the order unambiguous.
    def started_after_setup
      sleep 0.05
      start = Time.now
      sleep 0.05
      described_class.new(start:, written: [], stat: Lain::Shell::Executable::Stat.new)
    end

    it "is false when nothing under the root was written or changed in this lineage" do
      made("Gemfile")

      expect(lineage(after_every_file).any_under?(project)).to be(false)
    end

    it "is true once a write record names a file anywhere under the root, a workspace member's included" do
      file = made("crates/lain-fence/build.rs")
      fresh = lineage(after_every_file)
      journal << written(file)

      expect(fresh.any_under?(project)).to be(true)
    end

    it "is true when a file under the root has a ctime after the lineage started, with no write record" do
      made("lib/lain/version.rb")

      expect(lineage(before_every_file).any_under?(project)).to be(true)
    end

    it "matches a write record that names the root by its realpath when asked through a link" do
      file = made("Gemfile")
      File.symlink(project, link = File.join(root, "link"))
      fresh = lineage(after_every_file)
      journal << written(file)

      expect(fresh.any_under?(link)).to be(true)
    end

    it "ignores a write outside the root, and one in a directory whose name only starts like it" do
      fresh = lineage(after_every_file)
      journal << written(plant("elsewhere/Gemfile"))
      journal << written(plant("project-two/Gemfile"))

      expect(fresh.any_under?(project)).to be(false)
    end

    it "counts a write record in target/ or .git/objects, which only the ctime check leaves out" do
      %w[target/debug/build/x/build-script-build .git/objects/ab/cdef].each do |relative|
        fresh = lineage(after_every_file)
        journal << written(made(relative))

        expect(fresh.any_under?(project)).to be(true), relative
      end
    end

    it "ignores a changed ctime in target/ or .git/objects at the root" do
      made("Gemfile")
      FileUtils.mkdir_p([File.join(project, "target"), File.join(project, ".git/objects")])
      fresh = started_after_setup
      made("target/debug/out")
      made(".git/objects/ab/cdef")

      expect(fresh.any_under?(project)).to be(false)
    end

    it "still counts a changed ctime beside the 2 skipped dirs" do
      FileUtils.mkdir_p([File.join(project, "target"), File.join(project, ".git/objects")])
      fresh = started_after_setup
      made("src/new.rb")

      expect(fresh.any_under?(project)).to be(true)
    end

    it "still counts a write elsewhere under .git, or in a dir only named like a skipped one" do
      %w[.git/FETCH_HEAD .git/objects-x targets/x src/target/x crates/a/target/x].each do |relative|
        fresh = lineage(after_every_file)
        journal << written(made(relative))

        expect(fresh.any_under?(project)).to be(true), relative
      end
    end

    it "is true when it has degraded, though nothing was written and the lineage starts after every file" do
      degraded = described_class.new(start: Time.now + 3600, written: [], stat: Lain::Shell::Executable::Stat.new,
                                     degraded: true)

      expect(degraded.any_under?(project)).to be(true)
    end

    it "counts a fetch's FETCH_HEAD and a rewrite of .git/config by rename, so a grant withdraws the next" do
      FileUtils.mkdir_p(File.join(project, ".git"))
      config = made(".git/config")
      %w[FETCH_HEAD config].each do |name|
        fresh = started_after_setup
        name == "config" ? File.rename(made(".git/config.lock"), config) : made(".git/#{name}")

        expect(fresh.any_under?(project)).to be(true), name
      end
    end

    it "is true when the root cannot be read" do
      made("Gemfile")
      fresh = lineage(after_every_file)
      FileUtils.chmod(0o000, project)

      expect(fresh.any_under?(project)).to be(true)
    ensure
      FileUtils.chmod(0o755, project)
    end

    it "is true when an entry appears in a cargo workspace member, by the member's ctime" do
      made("crates/lain-fence/Cargo.toml")
      fresh = started_after_setup
      made("crates/lain-fence/build.rs")

      expect(fresh.any_under?(project)).to be(true)
    end

    it "is true when a top-level file is rewritten in place, with no write record" do
      gemfile = made("Gemfile")
      fresh = started_after_setup
      File.write(gemfile, "changed\n")

      expect(fresh.any_under?(project)).to be(true)
    end

    # The stated bound of a check that does not walk the tree: only a write record shows a deep in-place edit.
    it "misses an in-place edit 2 levels down that no write record names, and catches it once one does" do
      version = made("lib/lain/version.rb")
      fresh = lineage(after_every_file)
      before = fresh.any_under?(project)
      File.write(version, "changed\n")
      journal << written(version)

      expect([before, fresh.any_under?(project)]).to eq([false, true])
      expect(started_after_setup.tap { File.write(version, "again\n") }.any_under?(project)).to be(false)
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
