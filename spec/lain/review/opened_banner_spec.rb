# frozen_string_literal: true

# Extracted out of `cli/command/survey.rb` and `cli/command/review.rb`, where
# the banner was duplicated byte-for-byte -- the shape QA found already drifted
# from the protocol once, silently, because two files carried one instruction
# string about two different surfaces.
RSpec.describe Lain::Review::OpenedBanner do
  # The two rounds this banner is ever rendered for, named from the sets the
  # SOURCES answer with rather than from `%w[new]` and `%w[old new]` written
  # out here -- `Source::HEAD_SIDE_ONLY` is what `Source::Corpus#sides`
  # returns and `Source::BOTH_SIDES` is what a diff source returns, so a spec
  # spelling them by hand could go on passing after the vocabulary moved.
  let(:survey) { Lain::Review::Source::HEAD_SIDE_ONLY }
  let(:changeset) { Lain::Review::Source::BOTH_SIDES }

  # THE PIN: the banner names the command a survey or a changeset review
  # can actually answer, never the protocol-5 EPIC command whose guard
  # (`runtime/65_review.lua:93-98`) neither surface can ever satisfy.
  it "names :LainReviewVerdict with a verdict a human can copy, and never LainReviewDone" do
    banner = described_class.call("reviewing branch feature", sides: changeset)

    expect(banner).to include(":LainReviewVerdict #{Lain::Review::VERDICTS.first}")
    expect(banner).not_to include("LainReviewDone")
  end

  it "carries the headline through unchanged, first, so a survey and a review each keep their own" do
    banner = described_class.call("surveying /tmp/corpus at cumulative scope: 2 files", sides: survey)

    expect(banner).to start_with("surveying /tmp/corpus at cumulative scope: 2 files\n")
  end

  it "names :LainNote, the annotate verb both surfaces answer to" do
    banner = described_class.call("reviewing branch feature", sides: changeset)

    expect(banner).to include(":LainNote annotates")
  end

  it "names lain://review, where a survey and a changeset review are both drawn" do
    banner = described_class.call("reviewing branch feature", sides: changeset)

    expect(banner).to include("lain://review")
  end

  # The two facts that do NOT vary with the round. Asked of both rounds in
  # one example, because "still" is the whole claim -- a per-round motion that
  # took the sidebar's name or the hand-back gesture with it would pass either
  # half of this checked alone.
  it "names the sidebar and the hand-back gesture whichever round it describes" do
    [survey, changeset].each do |sides|
      banner = described_class.call("reviewing something", sides:)

      expect(banner).to include("lain://review")
      expect(banner).to include(":LainReviewVerdict #{Lain::Review::VERDICTS.first}")
    end
  end

  # A survey draws `sidebar | file`, so ONE motion lands on the file and a
  # second would carry the human out of the layout into whatever else the
  # tabpage holds -- which is the failure this example exists for: the banner is
  # the DOCUMENTED way in (`planning/survey-dogfood-2026-08-25.md:68`), so a
  # motion that overshoots is a human following instructions into nothing.
  it "teaches one motion on a one-sided round, where the file is the slot beside the sidebar" do
    banner = described_class.call("surveying /tmp/corpus at cumulative scope: 2 files", sides: survey)

    expect(banner).to include("<C-w>l reaches the file where :LainNote annotates")
  end

  # The negative half, and NOT redundant with the positive one: `<C-w>l<C-w>l`
  # CONTAINS `<C-w>l`, so the assertion above passes unchanged on the old
  # two-hop string. This is the one that fails if the motion never varied.
  it "does not leave the second hop on a one-sided round, which would overshoot the layout" do
    banner = described_class.call("surveying /tmp/corpus at cumulative scope: 2 files", sides: survey)

    expect(banner).not_to include("<C-w>l<C-w>l")
  end

  # Pinned as the WHOLE sentence rather than as a substring. "Unchanged"
  # is a claim about the byte string a human has already been taught, and only
  # an equality can carry it: every substring assertion in this file would go
  # on passing if a word moved or a clause were dropped around it. The VERDICT
  # is the one interpolation, because {Lain::Review::VERDICTS} is documented as
  # a set that will grow and this example is not the place that pins it.
  it "renders a changeset review's banner exactly as it reads today" do
    banner = described_class.call("reviewing branch feature", sides: changeset)

    expect(banner).to eq("reviewing branch feature\nwalk it in lain://review; " \
                         "<CR> opens a row beside you, <C-w>l<C-w>l reaches the file where " \
                         ":LainNote annotates, :LainReviewVerdict " \
                         "#{Lain::Review::VERDICTS.first} hands it back")
  end

  # The two rounds that ship, side by side. It is worth stating that they
  # differ by exactly one hop -- but it is NOT a pin on the derivation, and an
  # earlier edition of this comment wrongly claimed it was: `sides.length` and
  # `sides.index(FILE_SIDE).succ` agree on both of these, so this example
  # passes against either. The one below is where they part.
  it "differs by exactly one hop between the two rounds that ship" do
    hops = [survey, changeset].map { |sides| described_class.call("h", sides:).scan("<C-w>l").length }

    expect(hops).to eq([1, 2])
  end

  # THE DISCRIMINATING CASE, and the whole reason the motion is counted to the
  # file's slot rather than over the slots. `%w[new old]` is the file drawn
  # FIRST -- `sidebar | NEW | OLD` -- where the file is ONE hop away and there
  # are TWO slots, so the two derivations finally disagree and a `length`
  # implementation fails here. Not a round anything ships; a probe that makes
  # the derivation observable, which is the only thing that keeps the example
  # above from being a pin on nothing.
  it "counts to the file's slot and not over the slots, which only a reversed layout tells apart" do
    banner = described_class.call("h", sides: %w[new old])

    expect(banner.scan("<C-w>l").length).to eq(1)
  end

  # A round with no file side has no file to reach, and this REFUSES rather
  # than naming a motion that lands in a materialized base revision. The
  # refusal is `nil.succ` and not a worded one, which is the deliberate reading
  # of the loud-failure rule for a case no source can produce: it dies at the
  # mistake, in the one method that made the assumption, rather than rendering
  # a confident sentence about a layout that does not exist.
  it "refuses to name a motion for a round holding no file side at all" do
    expect { described_class.call("h", sides: %w[old]) }.to raise_error(NoMethodError)
  end
end
