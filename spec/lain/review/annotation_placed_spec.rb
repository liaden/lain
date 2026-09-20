# frozen_string_literal: true

require "stringio"

# One note a human left on a changeset. The changeset-shaped sibling of
# Epic::Annotation, which stays as-is: this one is keyed by an anchor id and a
# (path, side, line) rather than by an epic slug and a generation, and it carries
# the revision it was authored against.
RSpec.describe Lain::Review::AnnotationPlaced do
  def placed(**overrides)
    described_class.new(id: "1f0c-4b", path: "lib/lain/agent.rb", side: "new", line: 42,
                        anchor_text: "  @store.write(input)", text: "validate first",
                        kind: "note", drifted: false, revision: "d4e5f6", **overrides)
  end

  let(:record) { placed }

  it_behaves_like "a review journal record", "annotation_placed"

  # The line is a position, read exactly as strictly as the epic sibling's:
  # a truncated "42abc" would anchor the note to a line nobody named, and a
  # negative one to a line that cannot exist.
  it "refuses a line that is not the positive canonical integer the editor sent" do
    expect { placed(line: -3) }.to raise_error(ArgumentError, /line/)
    expect { placed(line: 0) }.to raise_error(ArgumentError, /line/)
    expect { placed(line: nil) }.to raise_error(ArgumentError, /line/)
    expect { placed(line: "42abc") }.to raise_error(ArgumentError, /line/)
    expect { placed(line: 42.9) }.to raise_error(ArgumentError, /line/)
    expect(placed(line: "42").line).to eq(42)
  end

  # The other half: refused at CONSTRUCTION, so nothing malformed ever reaches
  # the fd. A record refused on the way back out would already be on disk.
  it "refuses before the journal is ever written to" do
    io = StringIO.new
    journal = Lain::Journal.new(io:)

    expect { journal.record(placed(line: -3)) }.to raise_error(ArgumentError, /line/)
    expect(io.string).to be_empty
  end

  it "carries both sides of the diff and refuses a third" do
    expect(placed(side: "old").side).to eq("old")
    expect(placed(side: :new).side).to eq("new")
    expect { placed(side: "both") }.to raise_error(ArgumentError, /side/)
  end

  it "carries the three note kinds and refuses a fourth" do
    expect(Lain::Review::ANNOTATION_KINDS).to eq(%w[note question blocker])
    expect(placed(kind: :blocker).kind).to eq("blocker")
    expect { placed(kind: "praise") }.to raise_error(ArgumentError, /kind/)
  end

  # The revision is the whole point of this record over the epic sibling
  # (research open question 4b): an annotation validated against one diff and
  # submitted against another is a live bug in tuicr, and it is only avoidable if
  # the diff the human was looking at is on the record.
  it "refuses a note that does not name the revision it was authored against" do
    expect { placed(revision: nil) }.to raise_error(ArgumentError, /revision/)
    expect { placed(revision: "  ") }.to raise_error(ArgumentError, /revision/)
  end

  it "refuses a note with no id, no path, and no words" do
    expect { placed(id: nil) }.to raise_error(ArgumentError, /id/)
    expect { placed(path: "") }.to raise_error(ArgumentError, /path/)
    expect { placed(text: "  ") }.to raise_error(ArgumentError, /text/)
  end

  # Where this record parts company with Epic::Annotation, deliberately. That one
  # refuses a blank anchor_text because a prose document has no blank line worth
  # annotating; a diff does -- an added empty line is a real, anchorable position,
  # and refusing it would lose the human's words over a line they legitimately
  # chose. nil is a different fact from "": the reviewed revision held no line
  # at that position, and the note lands with no evidence rather than being lost.
  it "anchors to a blank line, and to a position with no evidence line" do
    expect(placed(anchor_text: "").anchor_text).to eq("")
    expect(placed(anchor_text: nil).anchor_text).to be_nil
  end

  # The leading indentation IS the evidence: drift is anchor_text against the
  # line the number now names, so an anchor stripped on the way in would compare
  # equal to a line that had been re-indented and report no drift. Nothing else
  # in this file would notice a `strip` here -- both sides of a round trip would
  # be stripped alike -- so this is the example that holds it.
  it "keeps an anchored line exactly as the document had it" do
    expect(placed(anchor_text: "    end").anchor_text).to eq("    end")
    expect(placed(text: " needs a spec ").text).to eq(" needs a spec ")
  end

  it "carries the drift flag as one boolean, and refuses anything else" do
    expect(placed(drifted: true).drifted).to be(true)
    expect { placed(drifted: nil) }.to raise_error(ArgumentError, "drifted must be true or false, got nil")
    expect { placed(drifted: "maybe") }
      .to raise_error(ArgumentError, 'drifted must be true or false, got "maybe"')
  end

  # Drift is a MEASUREMENT -- anchor_text against the line the number now names --
  # and a measurement nobody took is not the same fact as one that came back
  # false. A default would let a caller that never compared journal "did not
  # drift", which is the reading a later audit cannot tell from a real one. Every
  # caller that can place a note has already resolved the anchor, so requiring it
  # costs nothing and refuses the one case that would be a lie.
  it "requires the drift measurement rather than defaulting to a claim" do
    expect { described_class.new(**placed.to_h.except(:drifted)) }
      .to raise_error(ArgumentError, /drifted/)
  end

  # The guard is reachable WITHOUT the constructor, which is what makes the
  # numericality clause above WireInteger real rather than dead: the session
  # fold reads these records back in from the journal, where a line is already
  # an Integer and WireInteger is never called. Without this example the clause
  # deletes clean.
  it "re-refuses a line through its guard alone, where WireInteger cannot reach" do
    carrier = described_class.declared_carrier.build(line: -1)
    carrier.valid?

    expect(carrier.errors.where(:line).map(&:message))
      .to include(a_string_matching(/must be the diff line the note points at, got -1/))
  end
end
