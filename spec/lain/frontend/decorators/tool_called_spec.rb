# frozen_string_literal: true

RSpec.describe Lain::Frontend::Decorators::ToolCalled do
  let(:tokens) { Lain::Frontend::Theme::DEFAULT_TOKENS.merge(tool_header: %i[bold]) }
  let(:theme) { Lain::Frontend::Theme.new(pastel: Pastel.new(enabled: false), tokens:) }

  def record(**over)
    Lain::Telemetry::ToolCalled.new(tool_use_id: "toolu_01ab", tool: "edit_file", summary: "lib/a.rb", phase: "start",
                                    outcome: nil, seconds: nil, **over)
  end

  def rendered(**over) = described_class.new(record(**over)).render(theme)

  it "names the tool and its summary when the call starts" do
    expect(rendered).to eq("▸ [01ab] edit_file lib/a.rb")
  end

  it "adds the outcome and the time when the call ends" do
    expect(rendered(phase: "end", outcome: "ok", seconds: 0.4)).to eq("▸ [01ab] edit_file lib/a.rb  ok 0.4s")
  end

  it "carries the first line of an error in the outcome" do
    expect(rendered(phase: "end", outcome: "failed no such file", seconds: 1.0))
      .to eq("▸ [01ab] edit_file lib/a.rb  failed no such file 1.0s")
  end

  it "paints the line with the tool_header token" do
    pastel = Pastel.new(enabled: true)
    painted = described_class.new(record).render(Lain::Frontend::Theme.new(pastel:, tokens:, detect: -> { 16 }))

    expect(painted).to eq(pastel.decorate("▸ [01ab] edit_file lib/a.rb", :bold))
  end

  it "is one stamped, whole line" do
    decorator = described_class.new(record)

    expect([decorator.line_shaped?, decorator.stamped?]).to eq([true, true])
  end

  it "is what the frontend renders the record with" do
    expect(Lain::Frontend::Decorators.for(record)).to be_a(described_class)
  end
end
