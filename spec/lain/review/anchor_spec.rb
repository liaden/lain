# frozen_string_literal: true

require "stringio"

RSpec.describe Lain::Review::Anchor do
  def anchor(**overrides)
    described_class.new(
      path: "lib/lain/store.rb", side: :new, line: 14,
      anchor_text: "  @store.write(input)", revision: "abc123", **overrides
    )
  end

  it "is deeply frozen" do
    expect(anchor).to be_deeply_frozen
  end

  it "collapses two anchors at the same position under equality, hash, and uniq" do
    left = anchor
    right = anchor

    expect(left).to eq(right)
    expect(left.hash).to eq(right.hash)
    expect([left, right].uniq).to contain_exactly(left)
    expect(Set[left, right].size).to eq(1)
  end

  describe "id" do
    it "is generated when absent" do
      expect(anchor.id).to be_a(String)
      expect(anchor.id).not_to be_empty
    end

    it "is preserved when supplied, as replay must restore the journaled id" do
      expect(anchor(id: "journaled-id-42").id).to eq("journaled-id-42")
    end

    it "is excluded from equality, so a fresh anchor and its replayed twin still collapse" do
      fresh = anchor
      replayed = anchor(id: "some-other-id")

      expect(fresh.id).not_to eq(replayed.id)
      expect(fresh).to eq(replayed)
    end
  end

  describe "drift" do
    # Ten filler lines push the line under test to 14, matching the AC and the
    # default anchor's `line:` above -- padding, not signal.
    def padded_document(target_line)
      ((["# filler"] * 10) + ["module Lain", "  class Store", "    def write(input)", target_line]).join("\n")
    end

    it "reports no drift when line 14 still reads the anchor text" do
      expect(anchor.drifted?(padded_document("  @store.write(input)"))).to be(false)
    end

    it "reports drift when line 14 no longer reads the anchor text" do
      expect(anchor.drifted?(padded_document("  @store.write(validated)"))).to be(true)
    end

    # Pins the current, deliberate boolean: a line past the document's end and
    # an empty document both mean "no such line", which can never equal
    # anchor_text, so both report drifted -- exactly as a changed line does.
    # Distinguishing "moved" from "gone" is research open question 1
    # (anchor_text alone vs. surrounding context), which this card's third
    # escalation trigger fences off; this pins the boundary rather than
    # answering the question.
    it "reports drift for a line past the end of the document, not a special case" do
      expect(anchor(line: 99).drifted?(padded_document("irrelevant"))).to be(true)
    end

    it "reports drift against an empty document" do
      expect(anchor.drifted?("")).to be(true)
    end

    # The CRLF defect, and it was total rather than partial: a unified diff's
    # body carries the line exactly as the file holds it -- carriage return
    # included -- while `String#lines(chomp: true)` strips `\r\n` as readily as
    # `\n`. Every anchor into a CRLF file therefore compared `"x\r"` against
    # `"x"` and reported drift on a line nobody had touched. Splitting on `\n`
    # alone is git's own rule for cutting a file into diff lines, so the two
    # ends now agree by construction rather than by chomping alike.
    it "reports no drift on a CRLF line whose text is unchanged" do
      crlf = anchor(anchor_text: "  @store.write(input)\r")
      expect(crlf.drifted?(padded_document("  @store.write(input)\r"))).to be(false)
    end

    it "still reports drift when a CRLF line's text changes" do
      crlf = anchor(anchor_text: "  @store.write(input)\r")
      expect(crlf.drifted?(padded_document("  @store.write(validated)\r"))).to be(true)
    end

    # Named, so a PRODUCER of `anchor_text` can call the same function rather
    # than reimplement it and drift apart. `Review::Changeset` is that producer.
    it "answers the line rule it judges by, so a producer can agree by construction" do
      expect(described_class.lines("a\r\nb\n")).to eq(["a\r", "b"])
    end

    # A trailing newline TERMINATES the last line; it does not begin another.
    # `split("\n", -1)` alone said otherwise, and the phantom field it appends is
    # `""` -- which an anchored blank line matches exactly. So an anchor on the
    # last line of a file that has since LOST that line answered "not drifted"
    # against a document with no such line, reintroducing the one case the
    # paragraph above says cannot happen. git counts `"a\n"` as ONE line, and so
    # does this.
    it "reports drift for an anchored blank line the document no longer has" do
      expect(anchor(line: 2, anchor_text: "").drifted?("a\n")).to be(true)
    end

    # The other half of the rule, and why the fix is not simply dropping `-1`:
    # Ruby's default split discards EVERY trailing empty field, so a blank line
    # the document genuinely still holds would then report drift instead. Both
    # directions are pinned by consequence, not by the shape of the Array.
    it "reports no drift for a trailing blank line the document still has" do
      expect(anchor(line: 2, anchor_text: "").drifted?("a\n\n")).to be(false)
    end

    it "counts a document's lines as git does, ending in a newline or not" do
      expect(described_class.lines("a\nb")).to eq(%w[a b])
      expect(described_class.lines("a\n\n\n")).to eq(["a", "", ""])
      expect(described_class.lines("\n")).to eq([""])
      expect(described_class.lines("")).to eq([])
    end
  end

  it "refuses an unknown side loudly, naming it" do
    expect { anchor(side: :both) }
      .to raise_error(Lain::Review::Anchor::UnknownSide, /both/)
  end

  describe "line" do
    it "refuses line 0, naming the field and the value -- T2's hunk arithmetic can hand this in" do
      expect { anchor(line: 0) }.to raise_error(Lain::Review::Anchor::InvalidLine, /line/)
    end

    it "refuses a negative line" do
      expect { anchor(line: -1) }.to raise_error(Lain::Review::Anchor::InvalidLine, /-1/)
    end

    it "refuses a line given as a String rather than an Integer" do
      expect { anchor(line: "14") }.to raise_error(Lain::Review::Anchor::InvalidLine, /"14"/)
    end
  end

  describe "field shape" do
    it "refuses a nil path, naming the field" do
      expect { anchor(path: nil) }.to raise_error(Lain::Review::Anchor::InvalidField, /path/)
    end

    it "refuses a non-String path" do
      expect { anchor(path: 42) }.to raise_error(Lain::Review::Anchor::InvalidField, /path/)
    end

    it "refuses a nil anchor_text" do
      expect { anchor(anchor_text: nil) }.to raise_error(Lain::Review::Anchor::InvalidField, /anchor_text/)
    end

    it "accepts an empty anchor_text -- a blank line is a real anchorable position" do
      expect(anchor(anchor_text: "").anchor_text).to eq("")
    end

    it "refuses a nil revision" do
      expect { anchor(revision: nil) }.to raise_error(Lain::Review::Anchor::InvalidField, /revision/)
    end

    it "refuses an empty revision" do
      expect { anchor(revision: "") }.to raise_error(Lain::Review::Anchor::InvalidField, /revision/)
    end
  end

  describe "equality symmetry across subclasses" do
    # A digest collision across classes is the reason `Data`'s own == checks
    # the class at all (see Lain::ContentAddressed); the point here is only
    # that the check must not be direction-sensitive, so it must not answer
    # differently depending on which side of == is the subclass instance.
    it "answers the same on both sides of ==, at the same position, regardless of which side subclasses" do
      subclass = Class.new(described_class)
      sub = subclass.new(path: "lib/lain/store.rb", side: :new, line: 14,
                         anchor_text: "  @store.write(input)", revision: "abc123")
      parent = anchor

      expect(parent == sub).to eq(sub == parent)
      expect(parent == sub).to be(false)
    end
  end

  describe "journal round trip" do
    # id is "accepted when supplied, because replay has to restore the one
    # the journal recorded" -- so an anchor that cannot survive a real
    # journal write/read defeats the card's stated purpose. `to_journal`
    # emits `side` as the Symbol Data stored; NDJSON only has strings, so a
    # reader gets `"new"` back, not `:new`.
    it "reconstructs an equal anchor, with its original id, after a real journal write and read" do
      io = StringIO.new
      journal = Lain::Journal.new(io:, clock: -> { "T" })
      original = anchor
      journal.record(original)

      parsed = Lain::Journal.parse(io.string.each_line.first)
      replayed = described_class.new(path: parsed["path"], side: parsed["side"], line: parsed["line"],
                                     anchor_text: parsed["anchor_text"], revision: parsed["revision"],
                                     id: parsed["id"])

      expect(replayed).to eq(original)
      expect(replayed.id).to eq(original.id)
      expect(replayed.side).to eq(:new)
    end
  end

  describe "string interning" do
    # `.dup.freeze` unconditionally allocates, even when the input is already
    # a frozen literal (as every String literal is, under this file's own
    # `frozen_string_literal: true`). `String#-@` interns instead: an
    # already-frozen, ivar-free String with no work to do returns itself.
    it "does not allocate a new String for an already-frozen path" do
      literal = "already-frozen-path.rb"

      expect(anchor(path: literal).path).to equal(literal)
    end
  end

  # T5 independently declared Review::SIDES as Strings (the journal is the
  # durable artifact and every record stores Strings); Anchor's own domain is
  # Symbols. Two literals that happen to agree today is exactly the trap: this
  # pin is what would have caught T1's `%i[old new]` and T5's `%w[old new]`
  # drifting apart, and it only holds because Anchor derives from
  # Review::SIDES rather than declaring its own list.
  describe "SIDES" do
    it "agrees with Lain::Review::SIDES, the one place membership is decided" do
      expect(described_class::SIDES.map(&:to_s)).to eq(Lain::Review::SIDES)
    end
  end
end
