# frozen_string_literal: true

require "json"
require "tmpdir"

# The journal-discovery contract, owned once. Both `lain epic status` and
# `lain epic queue` read a project's whole session history to fold an epic that
# spans days and sessions, and the two used to state this rule twice -- the
# shape that cost this chunk a silent bug already (two duplicated whitespace
# lists).
#
# Five clauses, each spec'd here and nowhere else:
#   1. every `.ndjson` in the directory, `.btw` ephemerals INCLUDED
#   2. `Dir.children`, never `Dir.glob`
#   3. parsed through `Journal.records`; foreign lines skipped, never raised on,
#      and a torn line a sign-off could rest on refused unless the reader tolerates damage
#   4. ordered by `ts` ascending, with a STABLE tiebreak
#   5. a file that cannot be read is named, never skipped
RSpec.describe Lain::CLI::SessionJournals do
  subject(:journals) { described_class.new(dir: @dir, types:) }

  let(:tolerant) { described_class.new(dir: @dir, types:, damage: described_class::Tolerate) }
  let(:types) { %w[gate_decision gate_evidence] }

  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  def write(name, lines, dir: @dir)
    File.write(File.join(dir, name), lines.empty? ? "" : "#{lines.join("\n")}\n")
  end

  def record(type:, at:, id: "x") = JSON.generate("ts" => at, "type" => type, "id" => id)

  def ids = journals.map { |r| r["id"] }

  def halved(line) = line[0, line.size / 2]

  # Long enough that halving it tears the record body, not the prefix.
  def padded(type) = record(type:, at: "2026-07-28T09:00:00.000000Z", id: "x" * 200)

  def torn_decision = halved(padded("gate_decision"))

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

    it "skips a line that is not JSON at all, without raising, when the reader tolerates damage" do
      write("20260728T090000-1.ndjson",
            ["}{ not json", record(type: "gate_decision", at: "2026-07-28T09:00:01Z", id: "a")])

      expect(tolerant.map { |r| r["id"] }).to eq(["a"])
    end
  end

  # A torn line is damage, never somebody else's bytes: the only other writer
  # the skip contract names is a Rust tracing span, and a span is a whole JSON
  # line. So a fold that skipped a torn `gate_decision` folded a decision
  # nobody made -- a lost deferral reads as drained, and drained opens the next
  # stage.
  describe "a torn line" do
    let(:types) { ["landed"] }

    it "refuses when the torn line names a gate_decision, naming the file, the line and the remedy" do
      write("20260728T090000-1.ndjson",
            [record(type: "turn", at: "2026-07-28T08:59:00Z"), torn_decision,
             record(type: "landed", at: "2026-07-28T09:00:01Z", id: "a")])

      expect { journals.to_a }.to raise_error(described_class::Unreadable) { |error|
        expect(error.message).to include("20260728T090000-1.ndjson", "line 2", "gate_decision",
                                         "move the damaged file aside or repair the line", "nothing was decided")
        expect(error.message).not_to include("\n")
      }
    end

    it "refuses when the torn line names a stage_transition" do
      write("20260728T090000-1.ndjson",
            [halved(padded("stage_transition"))])

      expect { journals.to_a }.to raise_error(described_class::Unreadable, /line 1.*stage_transition/)
    end

    # Whichever types this reader keeps: a landing or a finish folds the same
    # directory, and a torn sign-off there is exactly as undecided.
    it "refuses a torn gate_decision even for a reader that keeps no gate_decisions" do
      write("20260728T090000-1.ndjson", [torn_decision])

      expect { journals.tally }.to raise_error(described_class::Unreadable)
    end

    it "refuses a line whose record type cannot be read at all" do
      write("20260728T090000-1.ndjson", ["}{ not json"])

      expect { journals.to_a }.to raise_error(described_class::Unreadable, /line 1.*no record type/)
    end

    it "refuses as a Lain::Error, so the CLI prints one line and not a backtrace" do
      write("20260728T090000-1.ndjson", [torn_decision])

      expect { journals.to_a }.to raise_error(Lain::Error)
    end

    it "counts and skips a torn line of a type no sign-off rests on" do
      write("20260728T090000-1.ndjson",
            [halved(padded("turn")),
             record(type: "landed", at: "2026-07-28T09:00:01Z", id: "a")])

      expect(ids).to eq(["a"])
      expect(journals.tally).to have_attributes(lines: 2, records: 1, unreadable: 1)
    end

    it "counts a torn gate_decision without refusing, for a reader that tolerates damage" do
      write("20260728T090000-1.ndjson", [torn_decision, record(type: "landed", at: "2026-07-28T09:00:01Z", id: "a")])

      expect(tolerant.map { |r| r["id"] }).to eq(["a"])
      expect(tolerant.tally).to have_attributes(unreadable: 1)
    end

    # A writer that appended after an unterminated tear fuses its next record
    # onto the torn one, so the sign-off behind a torn `turn` is torn too.
    it "refuses a torn line of an unwatched type that swallowed a sign-off, naming the sign-off" do
      write("20260728T090000-1.ndjson",
            [halved(padded("turn")) + padded("gate_decision"),
             record(type: "landed", at: "2026-07-28T09:00:01Z", id: "a")])

      expect { journals.to_a }.to raise_error(described_class::Unreadable, /line 1.*turn.*gate_decision/)
    end

    it "skips a torn line whose fused records are all of unwatched types" do
      write("20260728T090000-1.ndjson",
            [halved(padded("turn")) + padded("turn"), record(type: "landed", at: "2026-07-28T09:00:01Z", id: "a")])

      expect(ids).to eq(["a"])
    end
  end

  # A live writer's record can straddle two reads: the fold reaches the end of
  # the file while the write is visible only in part, and the rest arrives
  # before the next read. The two pieces are ONE line, never damage.
  describe "a record split across two reads" do
    let(:types) { %w[gate_decision landed] }
    let(:path) { File.join(@dir, "20260728T090000-1.ndjson") }

    # Deterministic: File.foreach yields the chosen line in two pieces, as
    # IO#gets does when the writer's bytes land between two calls. The original
    # is called WITH a block: its blockless Enumerator would re-enter this stub.
    def split_at(index)
      allow(File).to receive(:foreach).and_call_original
      allow(File).to receive(:foreach).with(path).and_wrap_original do |original, *args|
        Enumerator.new do |reads|
          at = -1
          original.call(*args) do |line|
            at += 1
            (at == index ? [line[0, 70], line[70..]] : [line]).each { |piece| reads << piece }
          end
        end
      end
    end

    it "rejoins a split record of an unwatched type rather than counting it as damage" do
      write("20260728T090000-1.ndjson",
            [padded("turn"), record(type: "landed", at: "2026-07-28T09:00:01Z", id: "a")])
      split_at(0)

      expect(ids).to eq(["a"])
      expect(journals.tally).to have_attributes(lines: 2, records: 1, unreadable: 0)
    end

    it "rejoins a split sign-off and keeps it as the record it is" do
      write("20260728T090000-1.ndjson", [padded("gate_decision")])
      split_at(0)

      expect(ids).to eq(["x" * 200])
    end

    it "names a later damaged line by its real line number" do
      write("20260728T090000-1.ndjson", [padded("turn"), padded("landed"), torn_decision])
      split_at(0)

      expect { journals.to_a }.to raise_error(described_class::Unreadable, /line 3 \(a torn gate_decision record\)/)
    end
  end

  # An unterminated LAST line is what a crash leaves, and also what a fold
  # sees while a session is still writing. The file's size tells the two
  # apart once: if it moved since the read began, the file is read again.
  describe "an unterminated last line" do
    let(:types) { %w[gate_decision landed] }
    let(:path) { File.join(@dir, "20260728T090000-1.ndjson") }
    let(:reads) { [] }

    def leave(*lines, tail:) = File.write(path, lines.map { |line| "#{line}\n" }.join + tail)

    # Each whole walk of the file ends with the writer appending `appends`'
    # next chunk, the way a live session's write lands after the fold's read.
    def writer_appends(*appends)
      allow(File).to receive(:foreach).and_call_original
      allow(File).to receive(:foreach).with(path).and_wrap_original do |original, *args|
        chunk = appends[reads.size]
        reads << :read
        Enumerator.new do |lines|
          original.call(*args) { |line| lines << line }
          File.write(path, chunk, mode: "a") if chunk
        end
      end
    end

    it "refuses a crash-torn sign-off tail, saying the last line is incomplete and what to do" do
      leave(record(type: "landed", at: "2026-07-28T08:59:00Z", id: "a"), tail: halved(padded("gate_decision")))

      expect { journals.to_a }.to raise_error(described_class::Unreadable) { |error|
        expect(error.message).to include("line 2", "incomplete last line", "gate_decision",
                                         "run again if a session is still writing; otherwise move the damaged " \
                                         "file aside or repair the line; nothing was decided")
      }
    end

    it "reads the file again when a writer finished the line after the read began, and folds it" do
      whole = padded("gate_decision")
      leave(tail: halved(whole))
      writer_appends("#{whole[(whole.size / 2)..]}\n")

      expect(ids).to eq(["x" * 200])
      expect(reads.size).to eq(2)
    end

    it "reads again only once, and refuses a sign-off tail still unterminated after it" do
      whole = padded("gate_decision")
      leave(tail: halved(whole))
      writer_appends("#{whole[(whole.size / 2)..]}\n#{halved(padded("stage_transition"))}", "more")

      expect { journals.to_a }.to raise_error(described_class::Unreadable, /incomplete last line at line 2/)
      expect(reads.size).to eq(2)
    end

    it "skips an unterminated tail of an unwatched type, as before" do
      leave(record(type: "landed", at: "2026-07-28T08:59:00Z", id: "a"), tail: halved(padded("turn")))

      expect(ids).to eq(["a"])
      expect(journals.tally).to have_attributes(lines: 2, unreadable: 1)
    end
  end

  # The sniff reads the NDJSON record prefix, which rests on `type` being the
  # key right after `ts`. spec/journalable_surface_spec.rb pins where that
  # order comes from, and the two records a sign-off rests on.
  describe described_class::Torn do
    it "reads the record type off an intact prefix" do
      expect(described_class.sniff(%({"ts":"2026-07-28T09:00:00.000000Z","type":"gate_decision","artifact_di)))
        .to eq("gate_decision")
    end

    it "reads nothing off a line torn inside the type" do
      expect(described_class.sniff(%({"ts":"2026-07-28T09:00:00.000000Z","type":"gate_dec))).to be_nil
    end

    it "reads nothing off a line that does not open with the stamp" do
      expect(described_class.sniff(%({"type":"gate_decision","ts":"2026-07-28T09:00:00.000000Z"}))).to be_nil
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

      expect(tolerant.tally).to have_attributes(files: 1, lines: 3, records: 1, unreadable: 1)
    end

    it "reports a journal of pure garbage as read-but-not-understood" do
      write("20260728T090000-1.ndjson", ["garbage", "more garbage"])

      expect(tolerant.tally).to have_attributes(files: 1, lines: 2, records: 0, unreadable: 2)
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
