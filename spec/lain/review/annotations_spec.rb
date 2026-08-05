# frozen_string_literal: true

# T16, the Ruby half: the notes an editor hands back, turned into the records
# the journal keeps. The editor half -- placing the marker, keeping the marks,
# MEASURING DRIFT, and building this payload in placement order -- is
# `spec/lain/frontend/neovim/annotate_spec.rb`, which drives a real nvim and
# then feeds its captured wire payload straight through this module, so the two
# halves meet on the same bytes rather than on two hand-written fixtures.
#
# DRIFT ARRIVES ON THE WIRE and is not computed here, which is the one thing
# about this module a reader is most likely to expect otherwise. Drift is the
# anchor text against the line the number NOW names, and that line lives in the
# editor's buffer -- which is neither the diff a session holds nor anything else
# Ruby has. So the measurement is taken where the buffer is, and this side's job
# is to refuse a note that arrives without one.
RSpec.describe Lain::Review::Annotations do
  # The wire shape T16's `:LainNoteDone` sends: String keys, because a lua table
  # crosses msgpack that way.
  def note(**overrides)
    { "path" => "lib/widget.rb", "side" => "new", "line" => 2,
      "anchor_text" => "  def call = 1", "text" => "check the arity",
      "kind" => "note", "revision" => "head1ff", "drifted" => false }
      .merge(overrides.transform_keys(&:to_s))
  end

  def settle(*notes) = described_class.settle(notes)

  describe "a note on the new side" do
    # AC1's Ruby half. The revision is the note's OWN -- stamped on the buffer it
    # was placed in and carried across the wire -- and deliberately not looked up
    # at settle time from whatever diff is on screen now. That lookup is the
    # tuicr defect {Review::AnnotationPlaced}'s `revision` member exists to make
    # detectable, so resolving it here would reintroduce it.
    it "records the new-side line, the head revision, and the human's words" do
      record = settle(note).first

      expect(record).to be_a(Lain::Review::AnnotationPlaced)
      expect(record.to_h.except(:id)).to eq(
        path: "lib/widget.rb", side: "new", line: 2, anchor_text: "  def call = 1",
        text: "check the arity", kind: "note", drifted: false, revision: "head1ff"
      )
    end

    # The id is the ANCHOR's, minted here, and it is what a later reader joins a
    # thread to. Two notes on the same line are two different notes.
    it "mints an anchor id per note rather than per position" do
      ids = settle(note, note).map(&:id)

      expect(ids.uniq.size).to eq(2)
      expect(ids).to all(match(/\A[0-9a-f-]{36}\z/))
    end
  end

  describe "a note on the old side" do
    # AC2. The old side's revision is the MERGE BASE, and it is a different
    # string from the new side's -- so a note that inherited one revision for
    # both sides would name a commit its line never existed in.
    it "records the old side and the merge-base revision it was authored against" do
      record = settle(note(side: "old", anchor_text: "  def call = 2", revision: "base0ff")).first

      expect(record.side).to eq("old")
      expect(record.revision).to eq("base0ff")
    end
  end

  describe "a drifted note" do
    # AC3. Kept and marked, never dropped: the words are the part nobody can
    # reconstruct, and a settle that silently discarded the note would lose them
    # at exactly the moment the human most wants them.
    it "is recorded with drifted true and its text intact" do
      record = settle(note(drifted: true)).first

      expect(record.drifted).to be(true)
      expect(record.text).to eq("check the arity")
      expect(record.anchor_text).to eq("  def call = 1")
    end

    it "records an undrifted note beside a drifted one, each with its own answer" do
      expect(settle(note, note(drifted: true), note).map(&:drifted)).to eq([false, true, false])
    end
  end

  describe "a note that reports no measurement" do
    # `drifted` is a MEASUREMENT, and {Review::AnnotationPlaced} gives it no
    # default precisely so a caller that never compared cannot journal "did not
    # drift" -- a reading a later audit cannot tell from a real one. A nil value
    # drops its key from a lua table entirely, so an omitted `drifted` is exactly
    # the shape a bookkeeping slip in the editor produces, and it is refused BY
    # NAME rather than defaulted to the answer most notes give.
    it "is refused rather than defaulted to false" do
      expect { settle(note.except("drifted")) }.to raise_error(ArgumentError, /drifted/)
    end

    it "is refused when the measurement is not a boolean at all" do
      expect { settle(note(drifted: "false")) }.to raise_error(ArgumentError, /drifted/)
      expect { settle(note(drifted: nil)) }.to raise_error(ArgumentError, /drifted/)
    end
  end

  describe "placement order" do
    # AC4, and the reason this module maps rather than sorts. ORDER IS THE
    # OUTPUT: the journal's order is the only record of which note the human
    # placed first, and 40/12/25 is chosen so that ANY sort -- by line, by
    # anchor, by anything positional -- reads differently from the answer.
    it "records three notes placed on lines 40, 12 and 25 in that order" do
      placed = [40, 12, 25].map { |line| note(line:, anchor_text: "line #{line}") }

      expect(described_class.settle(placed).map(&:line)).to eq([40, 12, 25])
    end

    it "answers an empty settle with no records rather than refusing" do
      expect(settle).to eq([])
    end
  end

  describe "the wire's spellings" do
    # A note authored in-process writes Symbols; one that crossed msgpack from
    # lua carries Strings. Normalizing once here beats every caller remembering
    # which side of the wire it is on -- the same correction
    # {Epic::Review::Annotations} already carries, where reading only Symbols
    # raised KeyError on every real note AFTER the settlement was journaled.
    it "reads a Symbol-keyed note the same as a String-keyed one" do
      expect(described_class.settle([note.transform_keys(&:to_sym)]).first.to_h.except(:id))
        .to eq(settle(note).first.to_h.except(:id))
    end

    it "reads the line as a positive canonical integer and refuses anything else" do
      expect(settle(note(line: "2")).first.line).to eq(2)
      expect { settle(note(line: 0)) }.to raise_error(ArgumentError, /line/)
      expect { settle(note(line: "2abc")) }.to raise_error(ArgumentError, /line/)
      expect { settle(note(line: 2.9)) }.to raise_error(ArgumentError, /line/)
    end

    # The tokens are stripped of the whitespace a wire adds and the two text
    # members never are: an anchored line's leading indentation is precisely the
    # evidence the editor's drift comparison used, so a strip here would leave
    # the record disagreeing with the measurement it carries.
    it "strips the whitespace a wire adds around a token and never around the text" do
      record = settle(note(side: " new ", kind: " note ", text: "  mind the indent  ")).first

      expect(record.side).to eq("new")
      expect(record.kind).to eq("note")
      expect(record.text).to eq("  mind the indent  ")
      expect(settle(note(anchor_text: "  def call = 1  ")).first.anchor_text).to eq("  def call = 1  ")
    end
  end

  describe "the vocabularies it judges against" do
    it "refuses a kind that is not one of the three" do
      expect { settle(note(kind: "praise")) }.to raise_error(ArgumentError, /kind/)
      expect(Lain::Review::ANNOTATION_KINDS.map { |kind| settle(note(kind:)).first.kind })
        .to eq(Lain::Review::ANNOTATION_KINDS)
    end

    it "refuses a side that names no half of a diff" do
      expect { settle(note(side: "both")) }.to raise_error(Lain::Review::Anchor::UnknownSide, /side/)
    end

    it "refuses a note with nothing in it, and one that names no revision" do
      expect { settle(note(text: "   ")) }.to raise_error(ArgumentError, /text/)
      expect { settle(note(revision: "")) }.to raise_error(Lain::Review::Anchor::InvalidField, /revision/)
    end
  end

  describe "an anchored blank line" do
    # A blank line in a diff is a real, anchorable position -- an added empty
    # line is a change a human may legitimately have an opinion about -- so ""
    # is an anchor and not a missing one. Absent is still refused: nil is not a
    # line, "" is, and the two are different facts.
    it "is an anchor, while no anchor at all is refused" do
      expect(settle(note(anchor_text: "")).first.anchor_text).to eq("")
      expect { settle(note(anchor_text: nil)) }.to raise_error(Lain::Review::Anchor::InvalidField, /anchor_text/)
    end
  end

  describe "what reaches the journal" do
    # ORDER IS THE OUTPUT, and the journal is where it becomes durable. The
    # records above are only half the claim: a reader gets the ORDER OF LINES in
    # the NDJSON and nothing else, so this pins that the order survives the
    # write.
    it "writes the notes as NDJSON in the order they were placed" do
      placed = [40, 12, 25].map { |line| note(line:, anchor_text: "line #{line}") }
      io = StringIO.new
      journal = Lain::Journal.new(io:)

      described_class.settle(placed).each { |record| journal.record(record) }

      written = io.string.lines.map { |line| JSON.parse(line) }
      expect(written.map { |entry| entry["line"] }).to eq([40, 12, 25])
      expect(written.map { |entry| entry["type"] }).to all(eq("annotation_placed"))
    end
  end
end
