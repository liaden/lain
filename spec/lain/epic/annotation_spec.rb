# frozen_string_literal: true

require "stringio"

# One note a human left on a reviewed document, journaled by {Review#settle}.
# It is the only epic record that carries a human's own words, so what it
# refuses is what the journal can never be asked to carry: a note with nothing
# in it, and a note whose position is unreadable.
RSpec.describe Lain::Epic::Annotation do
  def annotation(**overrides)
    described_class.new(epic_slug: "alpha", generation: 1, issue_id: "b2", line: 7,
                        anchor_text: "second body", text: "tighten this AC", **overrides)
  end

  it "journals under the underscored basename of its class" do
    expect(annotation.journal_type).to eq("annotation")
    expect(described_class::JOURNAL_TYPE).to eq("annotation")
  end

  it "round-trips through the journal, string-keyed, under its discriminator" do
    io = StringIO.new
    Lain::Journal.new(io:).record(annotation)

    found = Lain::Journal.records(io.string.lines, type: "annotation").to_a

    expect(found).to contain_exactly(
      hash_including("type" => "annotation", "epic_slug" => "alpha", "generation" => 1, "issue_id" => "b2",
                     "line" => 7, "anchor_text" => "second body", "text" => "tighten this AC", "drifted" => false)
    )
  end

  it "refuses an unnamed epic, an empty note, and a note anchored to nothing" do
    expect { annotation(epic_slug: nil) }.to raise_error(ArgumentError, /epic_slug/)
    expect { annotation(text: "  ") }.to raise_error(ArgumentError, /text/)
    expect { annotation(anchor_text: "") }.to raise_error(ArgumentError, /anchor_text/)
  end

  # The line is a position in the document, read exactly as strictly as the
  # generation beside it: a truncated `"7abc"` would anchor the note to a line
  # nobody named.
  it "refuses a line that is not the positive canonical integer the editor sent" do
    expect { annotation(line: 0) }.to raise_error(ArgumentError, /line/)
    expect { annotation(line: nil) }.to raise_error(ArgumentError, /line/)
    expect { annotation(line: "7abc") }.to raise_error(ArgumentError, /line/)
    expect { annotation(line: 7.9) }.to raise_error(ArgumentError, /line/)
    expect(annotation(line: "7").line).to eq(7)
  end

  # A note the human placed on a line that no longer says what they anchored it
  # to. Kept, because their words are the part nobody can reconstruct -- and
  # attributed to no issue, because the line number is no longer evidence of
  # which issue they meant.
  it "carries the drift flag as one boolean, and refuses anything else" do
    expect(annotation(drifted: true, issue_id: nil).drifted).to be(true)
    expect { annotation(drifted: nil) }.to raise_error(ArgumentError, /drifted/)
    expect { annotation(drifted: "maybe") }.to raise_error(ArgumentError, /drifted/)
  end

  it "keeps an unattributed note's absent issue absent rather than blank" do
    expect(annotation(issue_id: nil).issue_id).to be_nil
  end

  it "is a deeply frozen, shareable value" do
    expect(annotation).to be_deeply_frozen
  end
end
