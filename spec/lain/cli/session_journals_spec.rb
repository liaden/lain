# frozen_string_literal: true

require "json"
require "tmpdir"

# The journal-discovery contract, owned once. Both `lain epic status` and
# `lain epic queue` read a project's whole session history to fold an epic that
# spans days and sessions, and the two used to state this rule twice -- the
# shape that cost this chunk a silent bug already (T4's two whitespace lists).
#
# Five clauses, each spec'd here and nowhere else:
#   1. every `.ndjson` in the directory, `.btw` ephemerals INCLUDED
#   2. `Dir.children`, never `Dir.glob`
#   3. parsed through `Journal.records`; foreign lines skipped, never raised on
#   4. ordered by `ts` ascending, with a STABLE tiebreak
#   5. a file that cannot be read is named, never skipped
RSpec.describe Lain::CLI::SessionJournals do
  subject(:journals) { described_class.new(dir: @dir, types:) }

  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  let(:types) { %w[gate_decision gate_evidence] }

  def write(name, lines, dir: @dir)
    File.write(File.join(dir, name), lines.empty? ? "" : "#{lines.join("\n")}\n")
  end

  def record(type:, at:, id: "x") = JSON.generate("ts" => at, "type" => type, "id" => id)

  def ids = journals.map { |r| r["id"] }

  # Clause 1
  describe "the file set" do
    it "reads every .ndjson in the directory" do
      write("20260727T090000-1.ndjson", [record(type: "gate_decision", at: "2026-07-27T09:00:00Z", id: "a")])
      write("20260728T090000-2.ndjson", [record(type: "gate_decision", at: "2026-07-28T09:00:00Z", id: "b")])

      expect(ids).to eq(%w[a b])
    end

    # An epic gate decided during a `--btw` session is a thing that happened.
    # Dropping it is unsafe in BOTH directions: a lost terminal decision leaves
    # an answered item parked, a lost deferral reads as drained.
    it "INCLUDES ephemeral .btw sessions, unlike `lain sessions`' default view" do
      write("20260728T090000-2.btw.ndjson", [record(type: "gate_decision", at: "2026-07-28T09:00:00Z", id: "btw")])

      expect(ids).to eq(["btw"])
    end

    it "ignores files that are not .ndjson" do
      write("notes.md", ["# not a journal"])
      write("20260728T090000-2.wal", [record(type: "gate_decision", at: "2026-07-28T09:00:00Z", id: "wal")])

      expect(ids).to be_empty
    end

    it "keeps only the record types it was asked for" do
      write("20260728T090000-1.ndjson",
            [record(type: "gate_decision", at: "2026-07-28T09:00:00Z", id: "kept"),
             record(type: "turn", at: "2026-07-28T09:00:01Z", id: "dropped")])

      expect(ids).to eq(["kept"])
    end
  end

  # Clause 2 -- the reason the house idiom is Dir.children.
  describe "a directory whose NAME carries glob metacharacters" do
    it "is read as a name, not as a pattern" do
      nested = File.join(@dir, "sessions[1]")
      Dir.mkdir(nested)
      write("20260728T090000-1.ndjson", [record(type: "gate_decision", at: "2026-07-28T09:00:00Z", id: "a")],
            dir: nested)

      expect(described_class.new(dir: nested, types:).map { |r| r["id"] }).to eq(["a"])
    end
  end

  # Clause 3
  describe "lines that are not our records" do
    it "skips a foreign JSON object (a Rust tracing span sharing the fd) without raising" do
      write("20260728T090000-1.ndjson",
            [JSON.generate("ts" => "2026-07-28T09:00:00Z", "level" => "INFO", "target" => "lain_core"),
             record(type: "gate_decision", at: "2026-07-28T09:00:01Z", id: "a")])

      expect(ids).to eq(["a"])
    end

    it "skips a line that is not JSON at all, without raising" do
      write("20260728T090000-1.ndjson",
            ["}{ not json", record(type: "gate_decision", at: "2026-07-28T09:00:01Z", id: "a")])

      expect(ids).to eq(["a"])
    end
  end

  # Clause 4
  describe "ordering" do
    it "orders by ts across files, not by filename" do
      write("20260728T050000-1.ndjson", [record(type: "gate_decision", at: "2026-07-28T08:00:00Z", id: "late")])
      write("20260728T090000-2.ndjson", [record(type: "gate_decision", at: "2026-07-28T06:00:00Z", id: "early")])

      expect(ids).to eq(%w[early late])
    end

    # `sort_by` is NOT stable, so records sharing a ts must fall back to a
    # defined position -- file order by sorted name, then position in file --
    # or the walk differs run to run.
    it "breaks ts ties by file order then position, deterministically" do
      same = "2026-07-28T09:00:00Z"
      write("20260728T090000-1.ndjson", [record(type: "gate_decision", at: same, id: "a1"),
                                         record(type: "gate_decision", at: same, id: "a2")])
      write("20260728T090000-2.ndjson", [record(type: "gate_decision", at: same, id: "b1")])

      expect(ids).to eq(%w[a1 a2 b1])
      expect(described_class.new(dir: @dir, types:).map { |r| r["id"] }).to eq(%w[a1 a2 b1])
    end
  end

  # Clause 5
  describe "a file that cannot be read" do
    it "is named rather than skipped, so stale truth is never reported as current" do
      Dir.mkdir(File.join(@dir, "weird.ndjson"))

      expect { journals.to_a }.to raise_error(described_class::Unreadable, /weird\.ndjson/)
    end

    it "refuses as a Lain::Error, so the CLI prints a message and not a backtrace" do
      Dir.mkdir(File.join(@dir, "weird.ndjson"))

      expect { journals.to_a }.to raise_error(Lain::Error)
    end
  end

  # THE BLOCKER: "folded N journals" counts FILES, so it cannot tell "read one
  # journal and understood it" from "read one journal and understood none of
  # it". A surface whose job is to justify "nothing is outstanding" has to be
  # able to say which.
  describe "#tally" do
    it "counts files, lines, kept records, and lines it could not parse" do
      write("20260728T090000-1.ndjson",
            [record(type: "gate_decision", at: "2026-07-28T09:00:00Z", id: "a"),
             record(type: "turn", at: "2026-07-28T09:00:01Z", id: "t"),
             "}{ truncated"])

      expect(journals.tally).to have_attributes(files: 1, lines: 3, records: 1, unreadable: 1)
    end

    it "reports a journal of pure garbage as read-but-not-understood" do
      write("20260728T090000-1.ndjson", ["garbage", "more garbage"])

      expect(journals.tally).to have_attributes(files: 1, lines: 2, records: 0, unreadable: 2)
    end

    # A foreign JSON object parses fine; it is simply not ours. Counting it as
    # unreadable would cry wolf on every session that shared its fd with Rust.
    it "does not count a foreign JSON object as unreadable" do
      write("20260728T090000-1.ndjson",
            [JSON.generate("ts" => "2026-07-28T09:00:00Z", "level" => "INFO")])

      expect(journals.tally).to have_attributes(lines: 1, records: 0, unreadable: 0)
    end

    it "counts nothing at all for an empty directory" do
      expect(journals.tally).to have_attributes(files: 0, lines: 0, records: 0, unreadable: 0)
    end
  end
end
