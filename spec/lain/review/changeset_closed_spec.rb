# frozen_string_literal: true

# A round let go without a verdict: by a human's close, or by a refusal raised
# after its rails were bound. The two are told apart on the record, because one
# is a decision and the other is a ceiling.
RSpec.describe Lain::Review::ChangesetClosed do
  def closed(**overrides)
    described_class.new(changeset_digest: "cafe", closed_by: "human", **overrides)
  end

  let(:record) { closed }

  it_behaves_like "a review journal record", "changeset_closed"

  it "says who let the round go, from a closed set" do
    expect(Lain::Review::CLOSED_BY).to eq(%w[human refusal])
    expect(Lain::Review::CLOSED_BY).to contain_exactly(described_class::BY_HUMAN, described_class::BY_REFUSAL)
    expect(closed(closed_by: :refusal).closed_by).to eq("refusal")
    expect { closed(closed_by: "timeout") }.to raise_error(ArgumentError, %r{closed_by must be one of human/refusal})
  end

  it "refuses a close of nothing" do
    expect { closed(changeset_digest: nil) }.to raise_error(ArgumentError, /changeset_digest/)
  end

  it "carries no verdict, because closing is not a judgement" do
    expect(closed.to_h.keys).to contain_exactly(:changeset_digest, :closed_by)
  end
end
