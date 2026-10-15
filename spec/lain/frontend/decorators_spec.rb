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

  # A chunk is whatever the tool had written when the reader last woke
  # ({Sink::IOAdapter#write} passes it through untouched), so it may end
  # mid-line by design and the frontend must not terminate it.
  it "does not call its output line-shaped, since a chunk may end mid-line" do
    expect(described_class.new(event(bytes: "half a li"))).not_to be_line_shaped
  end

  describe ".for" do
    it "returns a decorator for a ToolOutput event" do
      expect(Lain::Frontend::Decorators.for(event)).to be_a(described_class)
    end

    it "returns a decorator for a ProviderRetry event, since T4 rendered it live" do
      retry_event = Lain::Telemetry::ProviderRetry.new(attempt: 1)

      expect(Lain::Frontend::Decorators.for(retry_event)).to be_a(Lain::Frontend::Decorators::ProviderRetry)
    end

    it "returns a decorator for a prompt whose closing line could not be written" do
      unclosed = Lain::Frontend::TTY::PromptUnclosed.new(error_class: "Errno::EIO", message: "gone")

      expect(Lain::Frontend::Decorators.for(unclosed)).to be_a(Lain::Frontend::Decorators::PromptUnclosed)
    end

    it "returns nil for an event it does not render, the seam skipping it silently" do
      expect(Lain::Frontend::Decorators.for(Lain::Telemetry::Dropped.new(count: 1))).to be_nil
    end
  end
end

RSpec.describe Lain::Frontend::Decorators::PromptUnclosed do
  let(:theme) { Lain::Frontend::Theme.new(pastel: Pastel.new(enabled: false)) }
  let(:unclosed) do
    Lain::Frontend::TTY::PromptUnclosed.new(error_class: "Errno::EIO",
                                            message: "Input/output error - the terminal hung up")
  end

  it "renders one attributed line saying what went unsaid about the prompt, and why" do
    rendered = described_class.new(unclosed).render(theme)

    expect(rendered).to start_with("[prompt] ").and include("Errno::EIO", "the terminal hung up")
    expect(rendered).to include("could not say how a prompt was decided")
    expect(rendered).not_to match(/[\r\n]/)
  end

  it "is line shaped, so the frontend ends its row" do
    expect(described_class.new(unclosed)).to be_line_shaped
  end
end

RSpec.describe Lain::Frontend::Decorators do
  [Lain::Frontend::Decorators::ToolOutput, Lain::Frontend::Decorators::PromptUnclosed,
   Lain::Frontend::Decorators::ProviderRetry, Lain::Frontend::Decorators::SnapshotDegraded,
   Lain::Frontend::Decorators::SnapshotNarrowed].each do |klass|
    it "#{klass.name.demodulize} is not stamped, so its output keeps its own shape" do
      expect(klass.instance_method(:stamped?).bind_call(klass.allocate)).to be(false)
    end
  end
end
