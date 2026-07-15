# frozen_string_literal: true

RSpec.describe Lain::Frontend::Decorators::ToolOutput do
  let(:pastel) { Pastel.new(enabled: false) }

  def event(tool_use_id: "tu_1", stream: :stdout, bytes: "hello\n")
    Lain::Telemetry::ToolOutput.new(tool_use_id:, stream:, bytes:)
  end

  it "renders the tool_use_id, stream, and bytes as one line" do
    rendered = described_class.new(event(tool_use_id: "tu_abc", stream: :stdout, bytes: "hi\n")).render(pastel)

    expect(rendered).to include("tu_abc").and include("stdout").and include("hi")
  end

  it "colorizes stderr bytes red when the palette is enabled" do
    colored = Pastel.new(enabled: true)
    rendered = described_class.new(event(stream: :stderr, bytes: "boom\n")).render(colored)

    expect(rendered).to include(colored.red("boom\n"))
  end

  it "leaves stdout bytes uncolored" do
    colored = Pastel.new(enabled: true)
    rendered = described_class.new(event(stream: :stdout, bytes: "plain\n")).render(colored)

    expect(rendered).to include("plain\n")
    expect(rendered).not_to include(colored.red("plain\n"))
  end

  describe ".for" do
    it "returns a decorator for a ToolOutput event" do
      expect(Lain::Frontend::Decorators.for(event)).to be_a(described_class)
    end

    it "returns nil for an event it does not present" do
      expect(Lain::Frontend::Decorators.for(Lain::Telemetry::Dropped.new(count: 1))).to be_nil
    end
  end
end
