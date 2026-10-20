# frozen_string_literal: true

RSpec.describe Lain::ModelTable do
  subject(:table) { described_class.new(%w[opus claude-opus-4-5 claude-opus-4-5-20251101x]) }

  it "answers the exact key even when a longer key is also contained" do
    expect(table.key_for("claude-opus-4-5")).to eq("claude-opus-4-5")
  end

  it "answers the longest key the name contains" do
    expect(table.key_for("claude-opus-4-5-20251101")).to eq("claude-opus-4-5")
  end

  it "answers nil for a name no key is contained in" do
    expect(table.key_for("gpt-4")).to be_nil
  end

  it "refuses a name two equal-length keys both match, naming both" do
    ambiguous = described_class.new(%w[alpha-x beta-yy gamma-z])
    expect { ambiguous.key_for("alpha-x-gamma-z") }
      .to raise_error(described_class::Ambiguous, /alpha-x.*gamma-z|gamma-z.*alpha-x/)
  end

  it "does not refuse two equal-length keys when only one is contained" do
    expect(described_class.new(%w[alpha-x gamma-z]).key_for("alpha-x-1")).to eq("alpha-x")
  end

  it "makes the 3 shipped tables pick the key it picks for one real model name" do
    name = "claude-opus-4-5-20251101"
    pick = ->(rows) { rows.fetch(described_class.new(rows.keys).key_for(name)) }

    expect([Lain::OutputCeiling.table_tokens(name), Lain::ContextWindow.default.window_tokens(name),
            Lain::PriceBook.default.price(name)])
      .to eq([pick.call(Lain::OutputCeiling::TABLE), pick.call(Lain::ContextWindow::DEFAULTS),
              pick.call(Lain::PriceBook::DEFAULTS)])
  end
end
