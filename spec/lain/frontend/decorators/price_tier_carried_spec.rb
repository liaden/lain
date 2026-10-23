# frozen_string_literal: true

# A crossing sent unasked because the human approved its model's tier earlier
# in the chat. The journal records it; this is what tells the human, who would
# otherwise not see that the later request was billed at the dearer rate.
RSpec.describe Lain::Frontend::Decorators::PriceTierCarried do
  let(:theme) { Lain::Frontend::Theme.new(pastel: Pastel.new(enabled: false)) }

  def crossed(decision)
    Lain::Telemetry::PriceTierCrossed.new(model: "claude-haiku-5-5", prompt_tokens: 104_000, boundary: 100_000,
                                          standard_cost: "0.0104", tier_cost: "0.052", decision:)
  end

  it "is what the frontend renders a carried crossing with" do
    expect(Lain::Frontend::Decorators.for(crossed(:carried))).to be_a(described_class)
  end

  it "leaves a crossing the human answered to the question that asked it" do
    expect(Lain::Frontend::Decorators.for(crossed(:approve))).to be_nil
  end

  it "names the model, the tokens and the tier rate, and the earlier approval it was sent under" do
    rendered = described_class.new(crossed(:carried)).render(theme)

    expect(rendered).to include("claude-haiku-5-5", "104,000 prompt tokens", "$0.052 at the tier rate",
                                "under your earlier approval")
    expect(rendered).not_to include("\n")
  end

  it "is one whole line the frontend may terminate" do
    expect(described_class.new(crossed(:carried)).line_shaped?).to be(true)
  end
end
