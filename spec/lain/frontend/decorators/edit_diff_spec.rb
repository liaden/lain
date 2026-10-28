# frozen_string_literal: true

RSpec.describe Lain::Frontend::Decorators::EditDiff do
  let(:tokens) { Lain::Frontend::Theme::DEFAULT_TOKENS.merge(added: %i[green], removed: %i[red]) }
  let(:pastel) { Pastel.new(enabled: true) }
  let(:theme) { Lain::Frontend::Theme.new(pastel:, tokens:, detect: -> { 16 }) }

  def record(removed: %w[a b], added: %w[x y z], hidden: 0)
    Lain::Telemetry::EditApplied.new(path: "lib/a.rb", removed:, added:, hidden:)
  end

  def decorator(**) = described_class.new(record(**))

  it "prefixes each old line with - painted removed and each new line with + painted added" do
    expect(decorator.render(theme).lines(chomp: true)).to eq(
      [pastel.decorate("-a", :red), pastel.decorate("-b", :red),
       pastel.decorate("+x", :green), pastel.decorate("+y", :green), pastel.decorate("+z", :green)]
    )
  end

  it "ends with a footer counting the lines it left out" do
    expect(decorator(removed: ["a"] * 20, added: ["x"] * 20, hidden: 40).render(theme).lines(chomp: true).last)
      .to eq("… 40 more lines")
  end

  it "has no footer when nothing was left out" do
    expect(decorator.render(theme)).not_to include("more lines")
  end

  it "is one whole line the frontend terminates, without a time stamp" do
    expect([decorator.line_shaped?, decorator.stamped?]).to eq([true, false])
  end

  it "escapes a control byte instead of painting it raw" do
    rendered = decorator(removed: [], added: ["a\e[31mb"]).render(theme)

    expect(rendered).to include('a\\e[31mb').and(satisfy { |text| text.count("\e") == 2 })
  end

  it "bounds what the tool may carry at 20 lines" do
    expect(described_class::LIMIT).to eq(20)
  end
end
