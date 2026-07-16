# frozen_string_literal: true

# Compare::Table is the one fixed-width table renderer behind both Compare's
# report and Bench::Sweep's -- extracted because the two had grown byte-identical
# private copies of the same layout rules. The rules are pinned here so neither
# caller's report can drift: first column left-justified (labels), the rest
# right-justified (numbers line up on the decimal), two spaces between columns,
# a dashed rule under the header.
RSpec.describe Lain::Compare::Table do
  subject(:rendered) do
    described_class.new(headers: %w[metric n mean], rows: [["total tokens", "2", "137.5"], ["cost", "2", "0.01"]]).to_s
  end

  it "renders header, dashed rule, then one line per row" do
    expect(rendered.lines.map(&:chomp)).to eq(
      [
        "metric        n   mean",
        "------------  -  -----",
        "total tokens  2  137.5",
        "cost          2   0.01"
      ]
    )
  end

  it "left-justifies the first column and right-justifies the rest" do
    lines = rendered.lines.map(&:chomp)
    expect(lines.last).to start_with("cost ")
    expect(lines.last).to end_with(" 0.01")
  end

  it "sizes each column to its widest cell, headers included" do
    wide_header = described_class.new(headers: ["a", "very wide header"], rows: [%w[x 1]]).to_s
    expect(wide_header.lines.first.chomp).to eq("a  very wide header")
    expect(wide_header.lines.to_a[1].chomp).to eq("-  ----------------")
  end

  it "is deterministic: the same inputs render byte-identical output" do
    twice = described_class.new(headers: %w[h], rows: [["v"]])
    expect(twice.to_s).to eq(twice.to_s)
  end
end
