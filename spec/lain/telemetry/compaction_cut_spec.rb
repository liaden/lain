# frozen_string_literal: true

# The record a committed compaction leaves: the seam it froze, the head it was
# committed at, the arm that collapsed it, which kind of cut it is, the ranges
# it collapsed, the cuts it supersedes, and a link to the cut it moved past. The EMITTER is spec'd where
# it lives -- `spec/lain/compaction/source_spec.rb` for when a cut commits and
# `spec/lain/session_record/replay_spec.rb` for what a resume does with one;
# what is asserted here is the VALUE.
RSpec.describe Lain::Telemetry::CompactionCut do
  subject(:record) { described_class.new(**fields) }

  let(:summary) { [{ "type" => "text", "text" => "what was asked, found and decided" }] }
  let(:collapse) { { "span" => %w[blake3:aaa blake3:ccc], "content" => summary } }
  let(:fields) do
    { digest: "blake3:ccc", head: "blake3:fff", strategy: "eager", kind: "advance", parent: nil,
      supersedes: [], collapses: [collapse], plan_step_completions: 1 }
  end
  let(:collapsing) do
    fields.merge(kind: "collapse", parent: "blake3:two", supersedes: %w[blake3:one blake3:two])
  end

  it "carries the seam, where it was committed, by which arm, and what this advance collapsed" do
    expect(record).to have_attributes(**fields)
  end

  it "carries the cuts a collapse supersedes, by their record addresses" do
    expect(described_class.new(**collapsing)).to have_attributes(kind: "collapse",
                                                                 supersedes: %w[blake3:one blake3:two])
  end

  it "refuses a kind it does not know" do
    expect { described_class.new(**fields, kind: "squash") }
      .to raise_error(ArgumentError, /kind must be one of advance, collapse, handoff/)
  end

  # An advance extends the seam past the cuts it holds; if it also claimed to
  # supersede one, a held render would drop ranges nothing re-recorded.
  it "refuses an advance that supersedes a cut" do
    expect { described_class.new(**fields, supersedes: %w[blake3:one]) }
      .to raise_error(ArgumentError, /an advance supersedes no cut/)
  end

  it "refuses a collapse that supersedes fewer than two cuts, which collapses nothing together" do
    expect { described_class.new(**collapsing, supersedes: %w[blake3:two]) }
      .to raise_error(ArgumentError, /a collapse supersedes at least two cuts/)
  end

  it "refuses supersedes that is not a list of addresses" do
    expect { described_class.new(**collapsing, supersedes: "blake3:one") }
      .to raise_error(ArgumentError, /supersedes must be a list of cut addresses/)
  end

  it "answers the endpoints of each range it newly collapsed, in order" do
    later = { "span" => %w[blake3:ddd blake3:eee], "content" => summary }

    expect(described_class.new(**fields, collapses: [collapse, later]).spans)
      .to eq([%w[blake3:aaa blake3:ccc], %w[blake3:ddd blake3:eee]])
  end

  it "journals under a type a reader can discriminate without inspecting its shape" do
    expect(record.journal_type).to eq("compaction_cut")
    expect(record.to_journal).to eq("type" => "compaction_cut", "digest" => "blake3:ccc", "head" => "blake3:fff",
                                    "strategy" => "eager", "kind" => "advance", "parent" => nil,
                                    "supersedes" => [], "collapses" => [collapse], "plan_step_completions" => 1)
  end

  # A resume folds this back from JSON, where every key is a String; a record
  # built from Symbol keys must carry the same bytes, or the replacement a
  # resumed session renders differs from the one the recorded session did --
  # and its address, which a child cut names, would move.
  it "normalizes what it carries, so a record read back from JSON is equal to the one written" do
    symbolic = described_class.new(**fields, collapses: [{ span: %w[blake3:aaa blake3:ccc],
                                                           content: [{ type: "text", text: summary.first["text"] }] }])
    parsed = JSON.parse(JSON.generate(record.to_journal)).except("type").transform_keys(&:to_sym)

    expect(symbolic).to eq(record)
    expect(described_class.new(**parsed)).to eq(record)
    expect(described_class.new(**parsed).address).to eq(record.address)
  end

  # The parent link is a RECORD address, never a source digest: a retreat and a
  # re-advance can commit a second cut at the same source digest with different
  # summary text, so source digests do not name a cut.
  it "is addressed by its whole content, so two cuts at one seam with different text differ" do
    retold = described_class.new(**fields, collapses: [collapse.merge("content" => [{ "type" => "text",
                                                                                      "text" => "told again" }])])

    expect(record.address).to start_with("blake3:")
    expect(retold.digest).to eq(record.digest)
    expect(retold.address).not_to eq(record.address)
  end

  # A range whose collapse answered DROP left no replacement, and the cut must
  # still say it collapsed -- otherwise a held render would retain those turns.
  it "accepts a range whose replacement is empty, which is a dropped range" do
    dropped = { "span" => %w[blake3:aaa blake3:aaa], "content" => [] }

    expect(described_class.new(**fields, collapses: [dropped]).collapses).to eq([dropped])
  end

  it "refuses a cut that names no seam" do
    expect { described_class.new(**fields, digest: nil) }
      .to raise_error(ArgumentError, /digest must name the source turn/)
  end

  it "refuses a cut that names no head it was committed at" do
    expect { described_class.new(**fields, head: nil) }
      .to raise_error(ArgumentError, /head must name the source head/)
  end

  it "refuses a cut that names no arm" do
    expect { described_class.new(**fields, strategy: nil) }
      .to raise_error(ArgumentError, /strategy must name the arm/)
  end

  it "refuses a cut that collapsed nothing new" do
    expect { described_class.new(**fields, collapses: []) }
      .to raise_error(ArgumentError, /collapses must name at least one collapsed range/)
  end

  it "refuses a collapse that does not name both endpoints and its content" do
    expect { described_class.new(**fields, collapses: [{ "span" => %w[blake3:aaa] }]) }
      .to raise_error(ArgumentError, /each be a \[first, last\] span and the content blocks/)
  end

  it "refuses a plan-step count that is not a non-negative Integer" do
    expect { described_class.new(**fields, plan_step_completions: -1) }
      .to raise_error(ArgumentError, /plan_step_completions/)
  end

  it "is deeply frozen, content included" do
    expect(Ractor.shareable?(record)).to be(true)
    expect(Ractor.shareable?(described_class.new(**collapsing))).to be(true)
  end
end
