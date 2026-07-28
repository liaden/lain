# frozen_string_literal: true

RSpec.describe Lain::Frontend::Decorators::ToolOutput do
  let(:theme) { Lain::Frontend::Theme.new(pastel: Pastel.new(enabled: false)) }
  let(:colored) { Lain::Frontend::Theme.new(pastel: Pastel.new(enabled: true)) }

  def event(tool_use_id: "tu_1", stream: :stdout, bytes: "hello\n")
    Lain::Telemetry::ToolOutput.new(tool_use_id:, stream:, bytes:)
  end

  it "renders the tool_use_id, stream, and bytes as one line" do
    rendered = described_class.new(event(tool_use_id: "tu_abc", stream: :stdout, bytes: "hi\n")).render(theme)

    expect(rendered).to include("tu_abc").and include("stdout").and include("hi")
  end

  it "maps the stream it is printing onto a token that names intent" do
    rendered = described_class.new(event(stream: :stderr, bytes: "boom\n")).render(colored)

    expect(rendered).to include(colored.paint(:tool_error, "boom\n"))
  end

  it "raises rather than rendering plain if Telemetry ever grows a stream this does not map" do
    unmapped = Struct.new(:tool_use_id, :stream, :bytes).new("tu_1", :stdlog, "hm\n")

    expect { described_class.new(unmapped).render(colored) }.to raise_error(KeyError, /stdlog/)
  end

  it "emits the same bytes that pinned red for stderr before the theme existed" do
    rendered = described_class.new(event(stream: :stderr, bytes: "boom\n")).render(colored)

    expect(rendered).to include(Pastel.new(enabled: true).red("boom\n"))
  end

  it "takes the attribution label from the theme's label token" do
    rendered = described_class.new(event(tool_use_id: "tu_abc", stream: :stdout)).render(colored)

    expect(rendered).to start_with(colored.paint(:label, "[tu_abc stdout]"))
  end

  it "leaves stdout bytes uncolored" do
    rendered = described_class.new(event(stream: :stdout, bytes: "plain\n")).render(colored)

    expect(rendered).to include("plain\n")
    expect(rendered).not_to include(Pastel.new(enabled: true).red("plain\n"))
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
