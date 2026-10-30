# frozen_string_literal: true

RSpec.describe Lain::Frontend::Decorators::AssistantText do
  let(:pastel) { Pastel.new(enabled: false) }
  let(:theme) { Lain::Frontend::Theme.new(pastel:) }

  def event(text) = Lain::Telemetry::AssistantText.new(text:)

  it "renders markdown as the reply path does, without the markers" do
    expect(described_class.new(event("Use **this** and `that`")).render(theme)).to eq("Use this and that")
  end

  it "paints through the theme's markdown tokens" do
    colored = Pastel.new(enabled: true)
    styled = Lain::Frontend::Theme.new(pastel: colored, detect: -> { 256 })
    painted = described_class.new(event("a `b`")).render(styled)

    expect(painted).to eq("#{colored.cyan("a ")}#{colored.yellow("b")}")
  end

  it "names the code rows the frontend must not wrap" do
    expect(described_class.new(event("hi\n```\ncode\n```")).verbatim_rows).to eq([1])
  end

  it "parses a reply's markdown once across render and verbatim_rows" do
    allow(Lain::Frontend::Markdown).to receive(:segments).and_call_original
    decorator = described_class.new(event("hi\n```\ncode\n```"))
    decorator.render(theme)
    decorator.verbatim_rows

    expect(Lain::Frontend::Markdown).to have_received(:segments).once
  end

  it "builds one decorator per event, each rendering its own text" do
    first, second = %w[one two].map { |text| Lain::Frontend::Decorators.for(event(text)) }

    expect([first.equal?(second), first.render(theme), second.render(theme)]).to eq([false, "one", "two"])
  end

  it "is a line, unstamped" do
    decorator = described_class.new(event("x"))

    expect([decorator.line_shaped?, decorator.stamped?]).to eq([true, false])
  end
end
