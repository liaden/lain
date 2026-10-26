# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Journal::Verify do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  let(:path) { File.join(@dir, "session.ndjson") }

  def write_chained(count, from: 1)
    Lain::Journal.open(path, chain: true) do |journal|
      (from...(from + count)).each { |n| journal.record("type" => "turn", "n" => n, "text" => "line #{n}") }
    end
  end

  def lines = File.readlines(path, mode: "rb")
  def rewrite(lines) = File.binwrite(path, lines.join)
  def verify(**) = described_class.new(path).call(**)

  describe "an untouched chained file" do
    before { write_chained(5) }

    it "is intact and reports the line count, where the chain begins and the tip" do
      expect(verify).to have_attributes(
        lines: 5, chained_from: 1, first_break: nil, reason: :intact, tip: Lain::Journal::Line.tip(path)
      )
    end

    it "reports an entry's own prev, renamed on a chained journal, as part of the record" do
      Lain::Journal.open(path, chain: true) { |journal| journal.record("type" => "turn", "prev" => "x") }

      expect(verify).to have_attributes(reason: :intact, lines: 6)
    end
  end

  describe "an edit to a middle record" do
    before { write_chained(5) }

    %w[ts type n text].each do |field|
      it "names line 4 when the #{field} field of line 3 changes by one byte" do
        edited = lines
        edited[2] = edited[2].sub(/("#{field}":"?)./, '\\1x')
        rewrite(edited)

        expect(verify).to have_attributes(reason: :edited, first_break: 4)
      end
    end

    it "names line 3 when the link on line 3 is itself changed" do
      edited = lines
      edited[2] = edited[2].sub(/"prev":"blake3:./) { |m| "#{m[0..-2]}#{m[-1] == "0" ? "1" : "0"}" }
      rewrite(edited)

      expect(verify).to have_attributes(reason: :edited, first_break: 3)
    end

    it "names only the first break when later lines are edited too" do
      edited = lines
      edited[2] = edited[2].sub("line 3", "line X")
      edited[4] = edited[4].sub("line 5", "line Y")
      rewrite(edited)

      expect(verify).to have_attributes(reason: :edited, first_break: 4, tip: nil)
    end
  end

  describe "a removed or inserted line" do
    before { write_chained(5) }

    it "names the line that took the removed one's place" do
      kept = lines
      kept.delete_at(2)
      rewrite(kept)

      expect(verify).to have_attributes(reason: :edited, first_break: 3)
    end

    it "names the line after an inserted one" do
      all = lines
      all.insert(2, %({"ts":"2026-01-01T00:00:00Z","type":"turn","n":99}\n))
      rewrite(all)

      expect(verify).to have_attributes(reason: :edited, first_break: 4)
    end

    it "names line 1 when the first line is removed" do
      rewrite(lines.drop(1))

      expect(verify).to have_attributes(reason: :edited, first_break: 1)
    end
  end

  describe "a file written before chaining existed" do
    it "is unchained, not failed" do
      Lain::Journal.open(path) { |journal| 3.times { |n| journal.record("type" => "turn", "n" => n) } }

      expect(verify).to have_attributes(reason: :unchained, lines: 3, chained_from: nil, first_break: nil)
    end

    it "still fails a kept tip it does not match" do
      Lain::Journal.open(path) { |journal| journal.record("type" => "turn") }

      expect(verify(tip: "blake3:#{"a" * 64}")).to have_attributes(reason: :tip_mismatch, first_break: 1)
    end

    it "is unchained when it is empty" do
      File.write(path, "")

      expect(verify).to have_attributes(reason: :unchained, lines: 0, tip: Lain::Journal::Line::ORIGIN)
    end

    it "is chained from the line where a chained reopen began, and intact" do
      Lain::Journal.open(path) { |journal| 2.times { |n| journal.record("type" => "turn", "n" => n) } }
      write_chained(2, from: 3)

      expect(verify).to have_attributes(reason: :intact, lines: 4, chained_from: 3, first_break: nil)
    end

    it "still names an edit of the line before the chain began" do
      Lain::Journal.open(path) { |journal| 2.times { |n| journal.record("type" => "turn", "n" => n) } }
      write_chained(2, from: 3)
      edited = lines
      edited[1] = edited[1].sub('"n":1', '"n":7')
      rewrite(edited)

      expect(verify).to have_attributes(reason: :edited, first_break: 3)
    end
  end

  describe "the last line, which no successor vouches for" do
    before { write_chained(5) }

    let(:kept) { verify.tip }

    def edit_last = rewrite(lines.tap { |all| all[4] = all[4].sub("line 5", "line X") })

    it "passes an edited last line when no tip was kept" do
      edit_last

      expect(verify).to have_attributes(reason: :intact)
    end

    it "names the last line against a kept tip" do
      tip = kept
      edit_last

      expect(verify(tip:)).to have_attributes(reason: :tip_mismatch, first_break: 5)
    end

    it "accepts a kept tip the file has since grown past" do
      tip = kept
      write_chained(2, from: 6)

      expect(verify(tip:)).to have_attributes(reason: :intact, lines: 7)
    end

    it "refuses a kept tip whose line was removed from the end" do
      tip = kept
      rewrite(lines.first(4))

      expect(verify(tip:)).to have_attributes(reason: :tip_mismatch, first_break: 4)
    end

    it "reports the line a kept tip was found at" do
      tip = kept
      write_chained(2, from: 6)

      expect(verify(tip:)).to have_attributes(tip_line: 5, lines: 7)
    end

    it "reports the last line as where an untouched file holds its tip" do
      expect(verify(tip: kept)).to have_attributes(tip_line: 5)
    end

    it "prefers a chain break to the tip verdict" do
      tip = kept
      rewrite(lines.tap { |all| all[1] = all[1].sub("line 2", "line X") })

      expect(verify(tip:)).to have_attributes(reason: :edited, first_break: 3)
    end
  end

  describe "a crash" do
    before { write_chained(3) }

    it "reads an unterminated last line as a torn tail, not an edit" do
      File.binwrite(path, '{"ts":"2026-01-01T00:00:00Z","type":"tu', mode: "ab")

      expect(verify).to have_attributes(reason: :torn_tail, first_break: 4, lines: 4)
    end

    it "links a torn tail the way a chained reopen will" do
      File.binwrite(path, '{"ts":"2026-01-01', mode: "ab")
      reported = verify.tip

      expect(reported).to eq(Lain::Journal::Line.tip(path))
    end

    it "reads a sealed crash line as covered by its successor, not as a break" do
      File.binwrite(path, '{"ts":"2026-01-01T00:00:00Z","type":"tu', mode: "ab")
      Lain::Journal.open(path, chain: true) { |journal| journal.record("type" => "session_closed") }

      expect(verify).to have_attributes(reason: :intact, lines: 5, first_break: nil, covered: [4])
    end

    it "still names a sealed line that was altered after the seal" do
      File.binwrite(path, '{"ts":"2026-01-01T00:00:00Z","type":"tu', mode: "ab")
      Lain::Journal.open(path, chain: true) { |journal| journal.record("type" => "session_closed") }
      rewrite(lines.tap { |all| all[3] = all[3].sub("tu", "xx") })

      expect(verify).to have_attributes(reason: :edited, first_break: 5)
    end

    it "does not report an intact file as covering anything" do
      expect(verify.covered).to eq([])
    end
  end

  describe "a foreign writer's line in the middle" do
    before { write_chained(4) }

    it "names the first break only, whatever follows" do
      all = lines
      all.insert(2, %({"type":"foreign"}\n))
      rewrite(all)

      expect(verify).to have_attributes(reason: :edited, first_break: 4)
    end

    it "breaks nothing when a chained writer reopened after it, but leaves the line before it unvouched" do
      File.binwrite(path, %({"type":"foreign"}\n), mode: "ab")
      write_chained(1, from: 5)

      expect(verify).to have_attributes(reason: :intact, lines: 6, covered: [], unvouched: [4])
    end
  end

  describe "the line before one that carries no link" do
    before { write_chained(3) }

    def edit_line(index) = rewrite(lines.tap { |all| all[index] = all[index].sub("line #{index + 1}", "line X") })

    it "is unvouched when a sealed crash line follows it, so an edit of it reads intact" do
      File.binwrite(path, '{"ts":"2026-01-01T00:00:00Z","type":"tu', mode: "ab")
      write_chained(1, from: 5)
      edit_line(2)

      expect(verify).to have_attributes(reason: :intact, covered: [4], unvouched: [3])
    end

    it "is unvouched when a chainless writer appended after it" do
      Lain::Journal.open(path) { |journal| journal.record("type" => "turn", "n" => 4) }
      edit_line(2)

      expect(verify).to have_attributes(reason: :intact, unvouched: [3])
    end

    it "is not reported for a torn tail, which the torn verdict already explains" do
      File.binwrite(path, '{"ts":"2026-01-01', mode: "ab")

      expect(verify.unvouched).to eq([])
    end

    it "is empty for an untouched chain" do
      expect(verify.unvouched).to eq([])
    end
  end

  it "verifies a megabyte line" do
    Lain::Journal.open(path, chain: true) do |journal|
      journal.record("type" => "turn", "text" => "a" * 1_000_000)
      journal.record("type" => "turn", "n" => 2)
    end

    expect(verify).to have_attributes(reason: :intact, lines: 2)
  end
end
