# frozen_string_literal: true

# The judgement, against the changeset it judged. Both halves are required: a
# verdict with no changeset digest is a judgement of nothing.
RSpec.describe Lain::Review::ReviewVerdict do
  def verdict(**overrides)
    described_class.new(verdict: "approve", changeset_digest: "cafe", **overrides)
  end

  let(:record) { verdict }

  it_behaves_like "a review journal record", "review_verdict"

  # Research open question 3 has not settled the vocabulary, so the set holds
  # exactly the one value this chunk writes. A second member is a design
  # decision, and this is what makes taking it deliberate rather than incidental.
  it "admits only the verdict the chunk has chosen" do
    expect(Lain::Review::VERDICTS).to eq(%w[approve])
    expect { verdict(verdict: "request_changes") }.to raise_error(ArgumentError, /verdict/)
  end

  # The refusal has to name the DECISION, not just the set. An agent that reads
  # "must be one of approve" concludes the set is too small and widens it; the
  # correct response is to stop, because the vocabulary is an open research
  # question and picking it is not this chunk's to do.
  it "refuses in a way that says the vocabulary is unsettled, not that the set is short" do
    expect { verdict(verdict: "request_changes") }
      .to raise_error(ArgumentError, /research open question 3/)
    expect { verdict(verdict: "request_changes") }
      .to raise_error(ArgumentError, /Review::VERDICTS/)
    expect { verdict(verdict: "request_changes") }
      .to raise_error(ArgumentError, /got "request_changes"/)
  end

  it "refuses a judgement of nothing" do
    expect { verdict(changeset_digest: nil) }.to raise_error(ArgumentError, /changeset_digest/)
  end
end
