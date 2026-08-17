# frozen_string_literal: true

# Extracted out of `cli/command/survey.rb` and `cli/command/review.rb` (T5
# fix round), where the banner was duplicated byte-for-byte -- the shape F4
# found already drifted from the protocol once, silently, because two files
# carried one instruction string about two different surfaces.
RSpec.describe Lain::Review::OpenedBanner do
  # THE F4 PIN: the banner names the command a survey or a changeset review
  # can actually answer, never the protocol-5 EPIC command whose guard
  # (`runtime/65_review.lua:93-98`) neither surface can ever satisfy.
  it "names :LainReviewVerdict with a verdict a human can copy, and never LainReviewDone" do
    banner = described_class.call("reviewing branch feature")

    expect(banner).to include(":LainReviewVerdict #{Lain::Review::VERDICTS.first}")
    expect(banner).not_to include("LainReviewDone")
  end

  it "carries the headline through unchanged, first, so a survey and a review each keep their own" do
    banner = described_class.call("surveying /tmp/corpus at cumulative scope: 2 files")

    expect(banner).to start_with("surveying /tmp/corpus at cumulative scope: 2 files\n")
  end

  it "names :LainNote, the annotate verb both surfaces answer to" do
    banner = described_class.call("reviewing branch feature")

    expect(banner).to include(":LainNote annotates")
  end

  it "names lain://review, where a survey and a changeset review are both drawn" do
    banner = described_class.call("reviewing branch feature")

    expect(banner).to include("lain://review")
  end
end
